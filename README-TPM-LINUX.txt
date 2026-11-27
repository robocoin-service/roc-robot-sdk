ROC Robot SDK - Linux TPM Installation

DeRAS portal: https://deras.robocoin.io/
SDK source: https://github.com/robocoin-service/roc-robot-sdk


Purpose
- Read the TPM signing public key. This SDK does not provision EK attestation.
- Ask the TPM private key to sign a challenge payload.
- Submit robotId, ownerUserId, sdkBindingToken, CPU/TPM information, public key fingerprint and signature to roc-server.
- Keep a TPM-signed heartbeat with DeRAS so the platform can see whether the robot Agent is online.
- Sign DeRAS order-stage challenges so the platform can verify the bound TPM device participated.


Recommended one-step install
1. Register a robot on the RoboCoin platform.
2. Copy the SDK binding token shown by the page.
3. On the Linux industrial PC, run:


curl -fsSL https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh | bash -s -- <sdkBindingToken>


Example:
curl -fsSL https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh | bash -s -- 8a7f2c4e9d7b4c0aa123456789abcdef


The installer clones the SDK repository, installs dependencies if apt-get is available, binds the TPM public key to the robot registration record, then creates and starts a systemd service named roc-robot-agent.


One-step local command after clone
bash roc-robot-tpm-sdk.sh bind <sdkBindingToken> [serverUrl] [tpmHandle]
Binding alone does not install the service. The default API base is https://deras.robocoin.io.


Stage verification command
bash roc-robot-tpm-sdk.sh stage <serverUrl> <verificationId> <orderId> <taskId> <robotId> <stage> <nonce> <challengePayload> [tpmHandle]


Stage example
bash roc-robot-tpm-sdk.sh stage http://your-server:8090 7 21 13 12 DEPARTED abc123 "orderId=21;taskId=13;robotId=12;..."


Agent command
bash roc-robot-tpm-sdk.sh agent <robotId> [serverUrl] [tpmHandle]


Agent example
bash roc-robot-tpm-sdk.sh agent 12


Agent behavior
After robot registration is confirmed by the user, the systemd service keeps the agent running on the industrial PC.
The agent sends a TPM-signed heartbeat every 30 seconds. DeRAS treats the robot as online only when the latest heartbeat is recent and verified.
When the provider clicks Departed/Start Request/End Request in DeRAS, the server creates a challenge.
The agent polls the server, signs the challenge with TPM, and submits the report automatically.


Service commands
sudo systemctl status roc-robot-agent
sudo systemctl restart roc-robot-agent
sudo journalctl -u roc-robot-agent -f

Read-only diagnostics: bash ~/roc-robot-sdk/roc-robot-tpm-sdk.sh doctor --json
This reports the local binding and heartbeat state without including identifying details.
Use DeRAS to confirm current online status before testing real hardware.
