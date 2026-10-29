FROM python:3.12-slim

WORKDIR /app

# Installed from local wheel files, so the build works without internet.
COPY wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links /wheels flask gunicorn

COPY app.py .

ARG APP_VERSION=v1
ARG BROKEN=false
ENV APP_VERSION=${APP_VERSION}
ENV BROKEN=${BROKEN}

EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--access-logfile", "-", "app:app"]
