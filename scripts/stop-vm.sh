#!/bin/bash

INSTANCE_ID="i-0b65d9fb63ede2e26"
REGION="ap-south-2"

echo "Stopping NovaPay EC2 instance..."
aws ec2 stop-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Instance stopped successfully."
aws ec2 describe-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name]' \
  --output table
