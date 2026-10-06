// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
const configParams = require("./config.params.json");

import { Construct } from "constructs";
import * as ssm from "aws-cdk-lib/aws-ssm";

/**
 * SSM parameter name prefix, e.g. "/MyApp/".
 * Set `hierarchy` in config.params.json, or override with env SSM_PARAMETERS_HIERARCHY when running `configure` / `cdk`.
 */
export function ssmParameterHierarchy(): string {
  const fromEnv = typeof process.env.SSM_PARAMETERS_HIERARCHY === "string" ? process.env.SSM_PARAMETERS_HIERARCHY.trim() : "";
  const base = fromEnv || configParams.hierarchy;
  if (!base) return "/";
  return base.endsWith("/") ? base : `${base}/`;
}

const SSM_NOT_DEFINED = "not-defined";

/** Value an optional parameter takes when it doesn't exist in SSM yet: its defaultValue, else false / "not-defined". */
export const optionalParamDefault = (param: any): string => String(param.defaultValue ?? (param.boolean ? false : SSM_NOT_DEFINED));

export const loadSSMParams = (scope: Construct) => {
  const params: any = {};
  const hierarchy = ssmParameterHierarchy();
  for (const param of configParams.parameters) {
    // Optional parameters may not exist yet in an environment: read them with their default instead of
    // failing synth. Required parameters keep failing loudly when missing.
    const fallback = param.required ? undefined : optionalParamDefault(param);
    const value = ssm.StringParameter.valueFromLookup(scope, `${hierarchy}${param.name}`, fallback);
    params[param.name] = param.boolean ? value.toLowerCase() === "true" : value;
  }
  return { ...params, SSM_NOT_DEFINED };
};

/**
 * How voice translation works in this environment, from translationEnabled and proxyEnabled. Every stack decides
 * from this one rule, so the webapp, the proxy and the permissions can never disagree:
 *  - "off": translationEnabled is false. The webapp is a plain softphone with the translation panels greyed out,
 *    no proxy is deployed, and no role has Bedrock, Transcribe, Translate or Polly permissions.
 *  - "proxy": the server-side proxy makes the AWS calls; the browser gets no AWS permissions.
 *  - "direct": the browser calls AWS itself with identity pool credentials.
 */
export const translationMode = (ssmParams: any): "off" | "proxy" | "direct" =>
  !ssmParams.translationEnabled ? "off" : ssmParams.proxyEnabled ? "proxy" : "direct";

/** Region for an optional per-service parameter (transcribeRegion, ...): its own value, else bedrockRegion. */
export const serviceRegion = (ssmParams: any, paramName: string): string =>
  ssmParams[paramName] === ssmParams.SSM_NOT_DEFINED ? ssmParams.bedrockRegion : ssmParams[paramName];

/** Comma-separated optional parameter as a list; empty when not-defined. */
export const optionalList = (ssmParams: any, paramName: string): string[] =>
  ssmParams[paramName] === ssmParams.SSM_NOT_DEFINED
    ? []
    : String(ssmParams[paramName])
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);

export const fixDummyValueString = (value: string): string => {
  if (value.includes("dummy-value-for-")) return value.replace(/\//g, "-");
  else return value;
};
