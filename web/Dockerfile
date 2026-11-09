FROM python:3.13-slim

WORKDIR /app
# 字体为可选项：若自备 FangZhengSongHei.ttf，把它放到 web/ 并在本行补上该文件名。
COPY server.py index.html favicon.ico ./

ENV DATA_DIR=/data \
    PORT=8000 \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8

RUN mkdir -p /data/attachments /data/md

EXPOSE 8000
CMD ["python", "server.py"]
