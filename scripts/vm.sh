#!/bin/bash

INSTANCE_ID="i-0b65d9fb63ede2e26"
REGION="ap-south-2"
KEY=~/.ssh/sre-lab-key.pem

IP=$(aws ec2 describe-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Connecting to NovaPay EC2 at $IP..."
ssh -i $KEY ubuntu@$IP
