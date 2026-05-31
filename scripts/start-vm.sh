#!/bin/bash

INSTANCE_ID="i-0b65d9fb63ede2e26"
REGION="ap-south-2"

echo "Starting NovaPay EC2 instance..."
aws ec2 start-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Waiting for instance to be running..."
aws ec2 wait instance-running \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Instance is running..."
aws ec2 describe-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
  --output table
