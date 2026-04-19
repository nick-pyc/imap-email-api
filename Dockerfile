FROM python:3.11-slim

WORKDIR /app

RUN pip install flask --no-cache-dir

COPY email_api.py .

RUN mkdir -p /app/data

ENV DB_PATH=/app/data/emailapi.db

EXPOSE 6060

CMD ["python3", "email_api.py"]
