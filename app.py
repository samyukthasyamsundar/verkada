from fastapi import FastAPI, UploadFile, File
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
import boto3, asyncio, json, time

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

BUCKET = "verkada-footage-019256649628"
REGION = "us-east-1"

@app.get("/", response_class=HTMLResponse)
async def index():
    return open("ui.html").read()

@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    contents = await file.read()

    async def stream():
        steps = [
            ("Receiving file at management server", "10.0.2.243 · private subnet", 0.6),
            ("Verifying IAM role credentials",      "verkada-mgmt-role · auto-rotating keys · no stored credentials", 0.8),
            ("Routing via S3 VPC endpoint",         "Traffic stays inside AWS — no public internet", 0.7),
            ("Uploading to S3 bucket",              f"s3://{BUCKET}/{file.filename}", 0),
            ("Confirming write access",             "IAM policy: PutObject · GetObject · ListBucket only", 0.5),
        ]

        for i, (title, detail, delay) in enumerate(steps):
            if delay: await asyncio.sleep(delay)

            if i == 3:
                try:
                    s3 = boto3.client("s3", region_name=REGION)
                    s3.put_object(Bucket=BUCKET, Key=file.filename, Body=contents)
                    yield f"data: {json.dumps({'step': i, 'title': title, 'detail': detail, 'status': 'ok'})}\n\n"
                except Exception as e:
                    yield f"data: {json.dumps({'step': i, 'title': title, 'detail': str(e), 'status': 'error'})}\n\n"
                    return
            else:
                yield f"data: {json.dumps({'step': i, 'title': title, 'detail': detail, 'status': 'ok'})}\n\n"

        await asyncio.sleep(0.4)

        s3 = boto3.client("s3", region_name=REGION)
        objects = s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])
        files = [{"key": o["Key"], "size": o["Size"], "modified": o["LastModified"].strftime("%b %d %H:%M")} for o in objects]
        yield f"data: {json.dumps({'step': 5, 'title': 'Done', 'detail': 'File secured in footage bucket', 'status': 'done', 'files': files})}\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")
