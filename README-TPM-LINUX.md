# Linux Identity and TPM Notes

ROC Robot SDK binds a Linux robot computer to a platform record and signs heartbeat and verification reports. Device identity is part of SDK Core and does not depend on a robot vendor.

## Identity modes

### TPM 2.0

TPM is the default and recommended mode. The private signing key is generated inside the TPM, marked non-exportable, and referenced through a persistent handle. Only the public key and fingerprints are reported.

Required commands:

```text
tpm2_getcap
tpm2_createprimary
tpm2_create
tpm2_load
tpm2_readpublic
tpm2_sign
tpm2_evictcontrol
```

### Software RSA

Software identity is disabled by default. Enable it only on devices where TPM is unavailable and local file-based key protection is acceptable:

```bash
export ROC_ALLOW_SOFTWARE_IDENTITY=1
```

The generated private key is stored with mode `0600` under `$ROC_SDK_HOME/tpm/`. It is never included in a report.

## Agent commands

Bind a registered robot:

```bash
./roc-robot-tpm-sdk.sh bind <sdkBindingToken> <serverUrl>
```

Run the signed heartbeat and verification agent:

```bash
./roc-robot-tpm-sdk.sh agent <robotId> <serverUrl>
```

Inspect local state without changing hardware:

```bash
./roc-robot-tpm-sdk.sh doctor <serverUrl>
```

The installer normally creates `roc-robot-agent.service`, so manual agent startup is only needed for troubleshooting.

## Generic report metadata

Identity reports use device-neutral fields such as:

- `deviceType`
- `deviceModel`
- `networkInterface`
- `enabledAdapters`
- `machineFingerprint`
- `platformIdentityType`
- `publicKeyFingerprint`

Vendor SDK paths, vendor network addresses, and vendor Bridge URLs belong to the relevant adapter and are not collected by Core.

## Security properties

- Binding tokens are provided at install time and are not stored in the repository.
- TPM private keys are non-exportable.
- Software private keys remain local and are permission-restricted.
- Reports include the exact signed payload and signature algorithm.
- Adapter discovery and capability probes do not initialize motion.
- Cloud task polling is not implemented by this release.
