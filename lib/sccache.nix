# mkSccacheEnv :: { bucket, endpoint, region?, keyPrefix?, useSsl? } -> { SCCACHE_* env vars }
#
# Generate environment variables for sccache with a shared S3-compatible
# backend. Pass the result as `extraEnv` to mkDevShell or mkDevShells.
_: {
  mkSccacheEnv = {
    bucket,
    endpoint,
    region ? "auto",
    keyPrefix ? null,
    useSsl ? false,
  }:
    assert builtins.isString bucket
      || throw "rs-harbor: mkSccacheEnv 'bucket' is required and must be a string";
    assert builtins.stringLength bucket > 0
      || throw "rs-harbor: mkSccacheEnv 'bucket' must not be empty";
    assert builtins.isString endpoint
      || throw "rs-harbor: mkSccacheEnv 'endpoint' is required and must be a string";
    assert builtins.stringLength endpoint > 0
      || throw "rs-harbor: mkSccacheEnv 'endpoint' must not be empty";
    {
      SCCACHE_BUCKET = bucket;
      SCCACHE_ENDPOINT = endpoint;
      SCCACHE_REGION = region;
      SCCACHE_S3_USE_SSL = if useSsl then "true" else "false";
}
    // (if keyPrefix != null then {SCCACHE_S3_KEY_PREFIX = keyPrefix;} else {});
}
