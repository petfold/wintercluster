#!/usr/bin/env python3
"""Minimal sigv4 S3 client for the harness (stdlib only)."""
import datetime, hashlib, hmac, os, sys, urllib.parse, urllib.request, urllib.error

EP = os.environ.get("S3_EP", "http://localhost:8333")
HOST = EP.split("//", 1)[1]
AK = os.environ.get("S3_ACCESS_KEY", "s3warmdev")
SK = os.environ.get("S3_SECRET_KEY", "s3warmdevsecret")
REGION, SERVICE = "us-east-1", "s3"


def canonical_query(params):
    """Canonical query string: percent-encoded, sorted by encoded key.

    Values need RFC3986 encoding — a prefix like "backups/name/" contains
    slashes, and leaving them raw makes the signature disagree with what the
    server canonicalises, which surfaces as a bare 403.
    """
    enc = sorted((urllib.parse.quote(k, safe=""), urllib.parse.quote(v, safe=""))
                 for k, v in (params or {}).items())
    return "&".join(f"{k}={v}" for k, v in enc)


def request(method, path, params=None, body=b"", headers=None):
    query = canonical_query(params)
    h = dict(headers or {})
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    h.update({"host": HOST, "x-amz-date": amzdate, "x-amz-content-sha256": payload_hash})
    signed = ";".join(sorted(k.lower() for k in h))
    canon_headers = "".join(f"{k}:{h[k].strip()}\n" for k in sorted(h, key=str.lower))
    canon = f"{method}\n{urllib.parse.quote(path, safe='/')}\n{query}\n{canon_headers}\n{signed}\n{payload_hash}"
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(canon.encode()).hexdigest()}"
    k = ("AWS4" + SK).encode()
    for part in (datestamp, REGION, SERVICE, "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    h["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                          f"SignedHeaders={signed}, Signature="
                          f"{hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()}")
    url = EP + path + (("?" + query) if query else "")
    req = urllib.request.Request(url, data=body or None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def header(headers, name):
    return next((v for k, v in headers.items() if k.lower() == name.lower()), None)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "mb":
        bucket = args[0]
        hdrs = {"x-swarm-recovery-recipient": args[1]} if len(args) > 1 else {}
        st, _, body = request("PUT", f"/{bucket}", headers=hdrs)
        # 409 BucketAlreadyOwnedByYou is fine: the harness is idempotent.
        if st not in (200, 409):
            sys.exit(f"create bucket {bucket}: {st} {body.decode()[:200]}")
        print(f"  bucket {bucket}: {st}")
    elif cmd == "ls":
        bucket = args[0]
        params = {"list-type": "2"}
        if len(args) > 1:
            params["prefix"] = args[1]
        st, _, body = request("GET", f"/{bucket}", params)
        if st != 200:
            sys.exit(f"list {bucket}: {st}")
        import re
        for key in re.findall(r"<Key>([^<]+)</Key>", body.decode()):
            print(key)
    elif cmd == "snapshot":
        bucket, label = args[0], args[1]
        st, _, body = request("PUT", f"/{bucket}", {"x-swarm-snapshot": label})
        print(body.decode())
        sys.exit(0 if st == 200 else 1)
    elif cmd == "head":
        bucket = args[0]
        st, h, _ = request("HEAD", f"/{bucket}")
        print(f"status={st} root={header(h,'x-swarm-bucket-root')} "
              f"seq={header(h,'x-swarm-commit-seq')} "
              f"recipient={header(h,'x-swarm-recovery-recipient')}")
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
