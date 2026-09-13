#!/usr/bin/env python3
"""
scripts/deploy-render.py

Triggers a deployment on Render for an image-backed web service using the Render REST API v1,
pins the exact image tag built in CI, polls for completion until 'live' or failure,
and outputs a rollback-friendly summary to GitHub Actions.
"""

import os
import sys
import json
import time
import ssl
import urllib.request
import urllib.error

RENDER_API_BASE = "https://api.render.com/v1"
POLL_INTERVAL_SECONDS = 15
MAX_TIMEOUT_SECONDS = 900  # 15 minutes


def make_request(url, api_key, method="GET", data=None):
    ctx = ssl.create_default_context()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "User-Agent": "StudentAppBackend-CI/1.0",
    }
    encoded_data = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        encoded_data = json.dumps(data).encode("utf-8")

    req = urllib.request.Request(url, data=encoded_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=ctx) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        print(f"HTTP Error {e.code} for {method} {url}: {err_body}", file=sys.stderr)
        raise
    except urllib.error.URLError as e:
        print(f"Network error connecting to {url}: {e.reason}", file=sys.stderr)
        raise


def get_latest_deploys(service_id, api_key, limit=2):
    url = f"{RENDER_API_BASE}/services/{service_id}/deploys?limit={limit}"
    try:
        resp = make_request(url, api_key, method="GET")
        items = resp if isinstance(resp, list) else resp.get("deploys", [])
        # Unwrap nested "deploy" object from each list entry (Render returns [{"cursor": "...", "deploy": {...}}])
        return [item.get("deploy", item) for item in items]
    except Exception as e:
        print(f"Warning: Could not fetch previous deploy history: {e}", file=sys.stderr)
        return []



def trigger_deploy(service_id, api_key, image_url):
    url = f"{RENDER_API_BASE}/services/{service_id}/deploys"
    payload = {
        "imageUrl": image_url,
        "clearCache": "do_not_clear"
    }
    print(f"Triggering Render deploy on service {service_id} with image: {image_url}...")
    resp = make_request(url, api_key, method="POST", data=payload)
    deploy_id = resp.get("id") or resp.get("deploy", {}).get("id")
    if not deploy_id:
        print(f"Error: Response did not contain a deploy ID: {resp}", file=sys.stderr)
        sys.exit(1)
    return deploy_id, resp


def poll_deploy_status(service_id, deploy_id, api_key):
    url = f"{RENDER_API_BASE}/services/{service_id}/deploys/{deploy_id}"
    start_time = time.time()
    last_status = None

    print(f"Waiting for deploy {deploy_id} to reach 'live' status (polling every {POLL_INTERVAL_SECONDS}s)...")

    while True:
        elapsed = int(time.time() - start_time)
        if elapsed > MAX_TIMEOUT_SECONDS:
            print(f"Error: Timed out waiting for deploy {deploy_id} after {elapsed}s", file=sys.stderr)
            return False, "timed_out", elapsed

        try:
            resp = make_request(url, api_key, method="GET")
            deploy = resp if "status" in resp else resp.get("deploy", {})
            status = deploy.get("status")

            if status != last_status:
                print(f"[{elapsed}s] Deploy status: {status}")
                last_status = status

            if status == "live":
                print(f"Deployment {deploy_id} is LIVE! (took {elapsed}s)")
                return True, status, elapsed
            elif status in ("build_failed", "update_failed", "canceled", "deactivated"):
                print(f"Error: Deployment {deploy_id} reached terminal failure state: '{status}'", file=sys.stderr)
                return False, status, elapsed

        except Exception as e:
            print(f"Warning: Transient error polling status: {e}", file=sys.stderr)

        time.sleep(POLL_INTERVAL_SECONDS)


def write_github_summary(service_id, deploy_id, status, elapsed, image_ref, prev_deploy, success):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return

    icon = "✅" if success else "❌"
    prev_id = prev_deploy.get("id", "N/A") if prev_deploy else "N/A"
    prev_image = (
        prev_deploy.get("image", {}).get("imageRef")
        or prev_deploy.get("image", {}).get("url")
        or prev_deploy.get("commit", {}).get("id")
        or "Previous Deploy"
    )
    render_dashboard_url = f"https://dashboard.render.com/web/{service_id}/deploys/{deploy_id}"

    markdown = f"""
## {icon} Render Deployment Report

| Field | Value |
| :--- | :--- |
| **Status** | {icon} `{status}` |
| **Service ID** | `{service_id}` |
| **Deploy ID** | [`{deploy_id}`]({render_dashboard_url}) |
| **Deployed Image** | `{image_ref}` |
| **Duration** | `{elapsed}s` |
| **Dashboard** | [View on Render Dashboard]({render_dashboard_url}) |

### 🔄 Rollback Information

If you need to roll back to the previous stable deployment:
- **Previous Deploy ID**: `{prev_id}`
- **Rollback Command**:
```bash
curl -X POST "https://api.render.com/v1/services/{service_id}/deploys" \\
  -H "Authorization: Bearer $RENDER_API_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{{"imageUrl": "{prev_image}"}}'
```
"""
    try:
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(markdown)
    except Exception as e:
        print(f"Warning: Could not write GITHUB_STEP_SUMMARY: {e}", file=sys.stderr)


def main():
    api_key = os.environ.get("RENDER_API_KEY", "").strip()
    service_id = os.environ.get("RENDER_SERVICE_ID", "").strip()
    image_ref = os.environ.get("IMAGE_REF", "").strip()

    if not api_key:
        print("=" * 70, file=sys.stderr)
        print("ERROR: RENDER_API_KEY secret is not configured in GitHub Actions.", file=sys.stderr)
        print("Please configure RENDER_API_KEY in your repository secrets:", file=sys.stderr)
        print("1. Go to your Render Dashboard -> Account Settings -> API Keys", file=sys.stderr)
        print("2. Create a new API Key", file=sys.stderr)
        print("3. In GitHub repo Settings -> Secrets and variables -> Actions, add secret:", file=sys.stderr)
        print("   Name: RENDER_API_KEY", file=sys.stderr)
        print("=" * 70, file=sys.stderr)
        sys.exit(1)

    if not service_id:
        print("=" * 70, file=sys.stderr)
        print("ERROR: RENDER_SERVICE_ID environment variable is not set.", file=sys.stderr)
        print("Please configure RENDER_SERVICE_ID in GitHub Actions repository variables or secrets:", file=sys.stderr)
        print("In GitHub repo Settings -> Secrets and variables -> Actions -> Variables tab (or Secrets):", file=sys.stderr)
        print("   Name: RENDER_SERVICE_ID", file=sys.stderr)
        print("   Value: srv-dajdfdm7bikc73blaigg", file=sys.stderr)
        print("=" * 70, file=sys.stderr)
        sys.exit(1)


    if not image_ref:
        short_sha = os.environ.get("GITHUB_SHA", "latest")[:7]
        image_ref = f"ghcr.io/rajeshm20/studentappbackend:sha-{short_sha}"

    print(f"Initiating deployment for service {service_id}")
    print(f"Target Image: {image_ref}")

    # 1. Fetch current deploy before triggering new one (for rollback)
    deploys = get_latest_deploys(service_id, api_key, limit=1)
    prev_deploy = deploys[0] if deploys else {}

    # 2. Trigger deploy with pinned image
    deploy_id, _ = trigger_deploy(service_id, api_key, image_ref)

    # 3. Poll status until live or failure
    success, status, elapsed = poll_deploy_status(service_id, deploy_id, api_key)

    # 4. Write summary
    write_github_summary(service_id, deploy_id, status, elapsed, image_ref, prev_deploy, success)

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
