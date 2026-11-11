FROM python:3.13-slim

WORKDIR /app
# 网页版使用系统默认字体，不附带任何字体文件。
COPY server.py index.html favicon.ico ./

ENV DATA_DIR=/data \
    PORT=8000 \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8

RUN mkdir -p /data/attachments /data/md

EXPOSE 8000
CMD ["python", "server.py"]
