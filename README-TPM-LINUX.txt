ROC Robot SDK - Linux TPM Installation

Purpose
- Read the TPM business public key and EK public key.
- Ask the TPM private key to sign a challenge payload.
- Submit robotId, ownerUserId, sdkBindingToken, CPU/TPM information, public key fingerprint and signature to roc-server.
- Sign DeRAS order-stage challenges so the platform can verify the bound TPM device participated.

Recommended one-step install
1. Register a robot on the RoboCoin platform.
2. Copy the SDK binding token shown by the page.
3. On the Linux industrial PC, run:

curl -fsSL https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh | ROC_SERVER_URL=http://172.16.18.187:8090 bash -s -- <sdkBindingToken>

Example:
curl -fsSL https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh | ROC_SERVER_URL=http://172.16.18.187:8090 bash -s -- 8a7f2c4e9d7b4c0aa123456789abcdef

The installer clones the SDK repository, installs dependencies if apt-get is available, binds the TPM public key to the robot registration record, then starts the Agent.

One-step local command after clone
./roc-robot-tpm-sdk.sh bind <sdkBindingToken> [serverUrl] [tpmHandle]

Register command
./roc-robot-tpm-sdk.sh register <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]

Legacy register command is still supported:
./roc-robot-tpm-sdk.sh <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]

Example
./roc-robot-tpm-sdk.sh register 12 3 http://your-server:8090 8a7f2c4e9d7b4c0aa123456789abcdef

Stage verification command
./roc-robot-tpm-sdk.sh stage <serverUrl> <verificationId> <orderId> <taskId> <robotId> <stage> <nonce> <challengePayload> [tpmHandle]

Stage example
./roc-robot-tpm-sdk.sh stage http://your-server:8090 7 21 13 12 DEPARTED abc123 "orderId=21;taskId=13;robotId=12;..."

Agent command
./roc-robot-tpm-sdk.sh agent <robotId> <serverUrl> [tpmHandle]

Agent example
./roc-robot-tpm-sdk.sh agent 12 http://your-server:8090

Agent behavior
After robot registration is confirmed by the user, keep the agent running on the industrial PC.
When the provider clicks Departed/Arrived/Start Request/End Request in DeRAS, the server creates a challenge.
The agent polls the server, signs the challenge with TPM, and submits the report automatically.

Binding rule
The SDK package can be copied, but the binding command belongs to one robot registration record.
After the first successful TPM signature verification, roc-server stores that TPM public key fingerprint on sys_rob.
Future reports for the same robotId must use the same TPM public key fingerprint, otherwise the server rejects the report.
The sdkBindingToken is valid for 10 minutes and becomes invalid immediately after a successful SDK binding report.

Success signal
For registration, the server response should contain signatureVerified=true, bindingStatus=BOUND or MATCHED, and reportId.
For stage verification, the server response should contain status=PASSED and signatureVerified=true.
