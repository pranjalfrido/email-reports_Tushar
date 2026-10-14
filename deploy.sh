#!/bin/bash
# Deploy Tushar's 3 email reports to Cloud Run + Cloud Scheduler
# Usage: bash email-reports_Tushar/deploy.sh   (run from MIS root)

set -e

PROJECT=frido-429506
REGION=asia-south1
SERVICE=ops-email-reports
IMAGE=gcr.io/$PROJECT/$SERVICE

echo "=== Building image ==="
gcloud builds submit --tag $IMAGE email-reports_Tushar/

echo "=== Deploying to Cloud Run ==="
gcloud run deploy $SERVICE \
  --image $IMAGE \
  --region $REGION \
  --platform managed \
  --no-allow-unauthenticated \
  --env-vars-file email-reports_Tushar/env.yaml \
  --memory 1Gi \
  --timeout 900

echo "=== Getting service URL ==="
SERVICE_URL=$(gcloud run services describe $SERVICE --region $REGION --format 'value(status.url)')
echo "Service URL: $SERVICE_URL"

echo "=== Setting up Cloud Scheduler (11:15 AM IST = 05:45 UTC) ==="
gcloud scheduler jobs delete ops-email-reports-daily --location $REGION --quiet 2>/dev/null || true

gcloud scheduler jobs create http ops-email-reports-daily \
  --location $REGION \
  --schedule "45 5 * * *" \
  --time-zone "UTC" \
  --uri "$SERVICE_URL" \
  --http-method GET \
  --oidc-service-account-email "$(gcloud iam service-accounts list --filter='email~compute' --format='value(email)' | head -1)" \
  --description "Frido Ops Email Reports — daily at 11:15 AM IST (cancelled-no-refund, UC sync audit, order-not-closed)"

echo ""
echo "Done. Scheduler will trigger daily at 11:15 AM IST."
echo "Service: $SERVICE_URL"
