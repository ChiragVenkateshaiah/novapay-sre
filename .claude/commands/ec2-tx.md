Tail and pretty-print the transaction audit log on EC2.

Read infrastructure/ansible/inventory.ini to get the EC2 host IP and SSH key path.

Then run:
```
ssh -i ~/.ssh/sre-lab-key.pem ubuntu@<EC2_IP> \
  "tail -n ${N:-20} /var/log/novapay/transactions.log | jq . && echo '=== Total lines: '$(wc -l < /var/log/novapay/transactions.log)"
```

If $ARGUMENTS is provided, use it as N (number of lines). Default is 20.

Also show the file size:
```
ssh -i ~/.ssh/sre-lab-key.pem ubuntu@<EC2_IP> \
  "ls -lh /var/log/novapay/transactions.log"
```
