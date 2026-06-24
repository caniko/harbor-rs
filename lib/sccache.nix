# mkSccacheEnv       :: { bucket, endpoint, region?, keyPrefix?, useSsl?, accessKeyId?, secretAccessKey? }
#                     -> { SCCACHE_*, AWS_* }
#
# mkSccacheCraneEnv  :: { enable?, package?, bucket?, endpoint?, region?, keyPrefix?, useSsl?,
#                         accessKeyId?, secretAccessKey?, connectTimeout? }
#                     -> { RUSTC_WRAPPER?, SCCACHE_*, AWS_* }
#
# Generate sccache environment variables for dev shells (mkSccacheEnv) or
# for injection into crane `commonArgs` for derivation-level sccache (mkSccacheCraneEnv).
# When `enable = false` or required S3 params are missing, mkSccacheCraneEnv returns {}.
_: let
  inherit (builtins) isString stringLength;

  # Build the base SCCACHE_* + AWS_* env var set shared by both functions.
  mkSccacheInner = {
    bucket,
    endpoint,
    region ? "auto",
    keyPrefix ? null,
    useSsl ? false,
    accessKeyId ? null,
    secretAccessKey ? null,
  }:
    assert isString bucket
      || throw "rs-harbor: mkSccacheEnv 'bucket' is required and must be a string";
    assert stringLength bucket > 0
      || throw "rs-harbor: mkSccacheEnv 'bucket' must not be empty";
    assert isString endpoint
      || throw "rs-harbor: mkSccacheEnv 'endpoint' is required and must be a string";
    assert stringLength endpoint > 0
      || throw "rs-harbor: mkSccacheEnv 'endpoint' must not be empty";
    {
      SCCACHE_BUCKET = bucket;
      SCCACHE_ENDPOINT = endpoint;
      SCCACHE_REGION = region;
      SCCACHE_S3_USE_SSL = if useSsl then "true" else "false";
    }
    // (if keyPrefix != null then {SCCACHE_S3_KEY_PREFIX = keyPrefix;} else {})
    // (if accessKeyId != null then {AWS_ACCESS_KEY_ID = accessKeyId;} else {})
    // (if secretAccessKey != null then {AWS_SECRET_ACCESS_KEY = secretAccessKey;} else {});
in {
  inherit mkSccacheInner;

  mkSccacheEnv = mkSccacheInner;

  mkSccacheCraneEnv = {
    enable ? true,
    package ? null,
    bucket ? null,
    endpoint ? null,
    region ? "auto",
    keyPrefix ? null,
    useSsl ? false,
    accessKeyId ? null,
    secretAccessKey ? null,
    connectTimeout ? "2",
  }:
    if !enable || bucket == null || endpoint == null
    then {}
    else {
      RUSTC_WRAPPER = package;
      SCCACHE_CONNECT_TIMEOUT = connectTimeout;
    }
    // mkSccacheInner {
      inherit bucket endpoint region keyPrefix useSsl accessKeyId secretAccessKey;
    };
}
