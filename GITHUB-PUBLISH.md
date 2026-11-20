# ROC Robot SDK GitHub Publish Guide

## DeRAS developer portal

Register the developer account and physical robot at [RoboCoin DeRAS](https://deras.robocoin.io/) before installing the SDK. The portal generates the robot-specific binding command used by `install.sh`.


## Repository files


Create a public GitHub repository, for example:


```text
https://github.com/<your-account>/roc-robot-sdk
```


Put these files at the repository root:


```text
install.sh
roc-robot-tpm-sdk.sh
README.txt
README-TPM-LINUX.txt
```


## Platform frontend config


After the repository is created, replace these placeholders:


```text
https://github.com/robocoin-service/roc-robot-sdk.git
https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh
```


Recommended `.env` values for `roc-app`:


```env
VUE_APP_ROC_SDK_REPO_URL=https://github.com/<your-account>/roc-robot-sdk.git
VUE_APP_ROC_SDK_INSTALL_URL=https://raw.githubusercontent.com/<your-account>/roc-robot-sdk/main/install.sh
