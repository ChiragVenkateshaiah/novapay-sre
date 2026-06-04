from flask import Flask, jsonify, request
import random
import time

app = Flask(__name__)

# Simulated payment database
payments = []

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "healthy", "service": "novapay-payment-api"})

@app.route('/pay', methods=['POST'])
def process_payment():
    data = request.get_json()
    
    # Simulate processing time
    time.sleep(random.uniform(0.1, 0.3))
    
    payment = {
        "id": f"PAY-{random.randint(10000, 99999)}",
        "amount": data.get("amount"),
        "status": "success",
        "timestamp": time.time()
    }
    payments.append(payment)
    return jsonify(payment), 200

@app.route('/payments', methods=['GET'])
def get_payments():
    return jsonify({
        "total": len(payments),
        "payments": payments[-10:]
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
