# Deployment Architecture

# Deployment Architecture

## Infrastructure Overview

```mermaid
graph TD
    subgraph Developer["Developer Workstation"]
        CONFIGURE["node configure.js\n(writes SSM params)"]
        CDK_DEPLOY["cdk deploy\n(cdk-stacks/)"]
        VITE_BUILD["npm run build\n(webapp/ → dist/)"]
    end

    subgraph SSM_Store["AWS SSM Parameter Store\n/Abbvie/NovaSonic/Dev/"]
        P1["cognitoDomainPrefix"]
        P2["cognitoCallbackUrls"]
        P3["cognitoLogoutUrls"]
        P4["connectInstanceURL"]
        P5["connectInstanceRegion"]
        P6["bedrockRegion"]
        P7["novaSonicModelId"]
    end

    subgraph Backend["CdkBackendStack\n(Abbvie-NovaSonic-Backend-Dev)"]
        COG_STACK["CognitoStack (Nested)\n- User Pool\n- Identity Pool\n- IAM Roles"]
        FCC_STACK["FrontendConfigStack (Nested)\n- Python Lambda\n- Custom Resource"]
    end

    subgraph Frontend["CdkFrontendStack\n(Abbvie-NovaSonic-Frontend-Dev)"]
        S3_BUCKET["S3 Bucket\n(WebAppRoot/ + WebAppStaging/)"]
        S3_DEP["FrontendS3DeploymentStack (Nested)\n- BucketDeployment"]
    end

    CONFIGURE --> SSM_Store
    VITE_BUILD --> CDK_DEPLOY
    CDK_DEPLOY --> Backend
    CDK_DEPLOY --> Frontend
    SSM_Store --> Backend
    Backend --> |outputs passed as props| Frontend
    COG_STACK --> |Cognito outputs| FCC_STACK
    FCC_STACK --> |frontend-config.js| S3_BUCKET
    S3_DEP --> |webapp/dist/*| S3_BUCKET
```

---

## CDK Stack Dependency Chain

```mermaid
graph LR
    A["1. SSM Parameters\n(configure.js)"]
    B["2. CdkBackendStack\n- Reads SSM params\n- Creates Cognito\n- Writes SSM output"]
    C["3. CdkFrontendStack\n- Receives backendStackOutputs\n- Creates S3 bucket\n- Deploys frontend\n- Injects config"]

    A --> B --> C
```

---

## Step-by-Step Deployment Process

```mermaid
flowchart TD
    S1["Step 1: Prerequisites\n- AWS CLI configured\n- Node.js + CDK installed\n- Connect instance ready\n- Bedrock Nova Sonic enabled"]
    S2["Step 2: Build Frontend\ncd webapp && npm install\nnpm run build\n→ webapp/dist/"]
    S3["Step 3: Configure SSM\ncd cdk-stacks\nnpm install\nnode config/configure.js\n(interactive CLI prompts)"]
    S4["Step 4: CDK Bootstrap\ncdk bootstrap\n(first time only)"]
    S5["Step 5: Deploy Backend\ncdk deploy Abbvie-NovaSonic-Backend-Dev\n→ Cognito User Pool\n→ Identity Pool\n→ IAM Roles\n→ SSM outputs"]
    S6["Step 6: Deploy Frontend\ncdk deploy Abbvie-NovaSonic-Frontend-Dev\n→ S3 Bucket\n→ frontend-config.js injected\n→ webapp/dist uploaded"]
    S7["Step 7: Post-Deploy\n- Note CloudFront/S3 URL\n- Add URL to Cognito callback URLs\n- Create Cognito users\n- Configure Connect contact flows"]
    S8["✅ App Live\nAgents browse to CloudFront URL\nLogin via Cognito Hosted UI\nStart taking translated calls"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7 --> S8
```

---

## Runtime AWS Service Dependencies

| Service | Purpose | Auth Mechanism |
|---|---|---|
| **Amazon Cognito User Pool** | Agent identity & login | OAuth2 hosted UI |
| **Amazon Cognito Identity Pool** | Exchange id_token for AWS creds | `GetCredentialsForIdentity` |
| **Amazon Bedrock Nova Sonic** | Real-time voice translation | STS temporary credentials |
| **Amazon Connect** | Contact centre + WebRTC | Connect Streams API |
| **Amazon S3** | Static web app hosting | Public (CloudFront) |
| **AWS SSM Parameter Store** | CDK deploy-time config | CDK IAM role |
| **AWS CloudFormation** | Stack lifecycle management | CDK IAM role |

---

## IAM Permissions Summary

```mermaid
graph TD
    subgraph Authenticated_Role["Cognito Authenticated Role (Agent in browser)"]
        P1["bedrock:InvokeModel → *"]
        P2["cognito-identity:* → *"]
        P3["cognito-sync:* → *"]
        P4["mobileanalytics:PutEvents → *"]
        P5["cognito-identity:GetCredentialsForIdentity → *"]
    end

    subgraph Unauthenticated_Role["Cognito Unauthenticated Role (blocked)"]
        P6["mobileanalytics:PutEvents → *"]
        P7["cognito-sync:* → *"]
    end

    subgraph Lambda_Role["FrontendConfig Lambda Role"]
        P8["s3:PutObject → bucket/WebAppStaging/frontend-config.zip"]
        P9["s3:DeleteObject → bucket/WebAppStaging/frontend-config.zip"]
        P10["s3:PutObject → bucket/WebAppRoot/frontend-config.js"]
        P11["s3:DeleteObject → bucket/WebAppRoot/frontend-config.js"]
    end
```

---

## Configuration Parameters Reference

| Parameter | SSM Path | Example Value | Required |
|---|---|---|---|
| `cognitoDomainPrefix` | `/Abbvie/NovaSonic/Dev/cognitoDomainPrefix` | `abbvie-v2v-connect` | ✅ |
| `cognitoCallbackUrls` | `/Abbvie/NovaSonic/Dev/cognitoCallbackUrls` | `https://xxx.cloudfront.net` | ✅ |
| `cognitoLogoutUrls` | `/Abbvie/NovaSonic/Dev/cognitoLogoutUrls` | `https://xxx.cloudfront.net` | ✅ |
| `connectInstanceURL` | `/Abbvie/NovaSonic/Dev/connectInstanceURL` | `https://alias.my.connect.aws` | ✅ |
| `connectInstanceRegion` | `/Abbvie/NovaSonic/Dev/connectInstanceRegion` | `us-east-1` | ✅ |
| `bedrockRegion` | `/Abbvie/NovaSonic/Dev/bedrockRegion` | `us-east-1` | ✅ |
| `novaSonicModelId` | `/Abbvie/NovaSonic/Dev/novaSonicModelId` | `amazon.nova-2-sonic-v1:0` | ✅ |
