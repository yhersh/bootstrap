import { SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import { BOOTSTRAP_VERSION } from "../src/worker";
import fedoraScript from "../scripts/fedora.sh";
import macosScript from "../scripts/macos.sh";
import windowsScript from "../scripts/windows.ps1";
import releaseManifest from "../releases/manifest.json";

async function fetchWorker(path: string, init: RequestInit = {}) {
  return SELF.fetch(`https://bootstrap.yaronhersh.xyz${path}`, init);
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

describe("bootstrap worker routes", () => {
  it("manifest sha256 values match bundled script bytes", async () => {
    expect(releaseManifest.scripts.fedora.sha256).toBe(await sha256Hex(fedoraScript));
    expect(releaseManifest.scripts.macos.sha256).toBe(await sha256Hex(macosScript));
    expect(releaseManifest.scripts.windows.sha256).toBe(await sha256Hex(windowsScript));
  });

  it("serves usage on /", async () => {
    const response = await fetchWorker("/");
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(text).toContain("bootstrap.yaronhersh.xyz");
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
    expect(response.headers.get("X-Bootstrap-Version")).toBe(BOOTSTRAP_VERSION);
  });

  it("serves fedora script bytes on /fedora", async () => {
    const response = await fetchWorker("/fedora");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(fedoraScript);
    expect(response.headers.get("Content-Type")).toBe("text/plain; charset=utf-8");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Content-Security-Policy")).toBe("default-src 'none'");
  });

  it("serves windows script bytes on /windows", async () => {
    const response = await fetchWorker("/windows");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(windowsScript);
  });

  it("serves macos script bytes on /macos", async () => {
    const response = await fetchWorker("/macos");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(macosScript);
    expect(response.headers.get("Content-Type")).toBe("text/plain; charset=utf-8");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(response.headers.get("Content-Security-Policy")).toBe("default-src 'none'");
  });

  it("serves immutable exact version and checksum", async () => {
    const exact = await fetchWorker(`/fedora/v${BOOTSTRAP_VERSION}`);
    expect(exact.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(await exact.text()).toBe(fedoraScript);

    const checksum = await fetchWorker(`/fedora/v${BOOTSTRAP_VERSION}.sha256`);
    expect(checksum.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    const checksumText = await checksum.text();
    expect(checksumText).toMatch(/^[a-f0-9]{64}\s+fedora\.sh\n$/);

    const digest = checksumText.split(/\s+/)[0];
    const data = new TextEncoder().encode(fedoraScript);
    const hashBuffer = await crypto.subtle.digest("SHA-256", data);
    const expected = [...new Uint8Array(hashBuffer)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    expect(digest).toBe(expected);
  });

  it("serves macos immutable exact version and checksum", async () => {
    const exact = await fetchWorker(`/macos/v${BOOTSTRAP_VERSION}`);
    expect(exact.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(await exact.text()).toBe(macosScript);

    const checksum = await fetchWorker(`/macos/v${BOOTSTRAP_VERSION}.sha256`);
    expect(checksum.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    const checksumText = await checksum.text();
    expect(checksumText).toMatch(/^[a-f0-9]{64}\s+macos\.sh\n$/);

    const digest = checksumText.split(/\s+/)[0];
    const data = new TextEncoder().encode(macosScript);
    const hashBuffer = await crypto.subtle.digest("SHA-256", data);
    const expected = [...new Uint8Array(hashBuffer)]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    expect(digest).toBe(expected);
  });

  it("serves /macos/v1 alias", async () => {
    const response = await fetchWorker("/macos/v1");
    expect(await response.text()).toBe(macosScript);
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
  });

  it("serves /fedora/v1 alias", async () => {
    const response = await fetchWorker("/fedora/v1");
    expect(await response.text()).toBe(fedoraScript);
    expect(response.headers.get("Cache-Control")).toBe("public, max-age=300");
  });

  it("serves manifest and healthz", async () => {
    const manifest = await fetchWorker("/releases/manifest.json");
    expect(manifest.status).toBe(200);
    const manifestJson = (await manifest.json()) as {
      scripts: { fedora: { sha256: string }; macos: { sha256: string }; windows: { sha256: string } };
    };
    expect(manifestJson).toEqual(releaseManifest);
    expect(manifestJson.scripts.fedora.sha256).toMatch(/^[a-f0-9]{64}$/);

    const health = await fetchWorker("/healthz");
    expect(health.status).toBe(200);
    expect(health.headers.get("Cache-Control")).toBe("no-store");
    const healthJson = (await health.json()) as {
      version: string;
      manifest: { scripts: { fedora: { sha256: string } } };
    };
    expect(healthJson.version).toBe(BOOTSTRAP_VERSION);
    expect(healthJson.manifest).toEqual(releaseManifest);
    expect(healthJson.manifest.scripts.fedora.sha256).toMatch(/^[a-f0-9]{64}$/);
  });

  it("returns 404 for unknown paths", async () => {
    const response = await fetchWorker("/missing");
    expect(response.status).toBe(404);
  });

  it("returns 405 for unsupported methods with Allow header", async () => {
    const response = await fetchWorker("/fedora", { method: "POST" });
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET, HEAD");
  });

  it("HEAD matches GET metadata with empty body", async () => {
    const getResponse = await fetchWorker("/fedora");
    const getBody = await getResponse.text();

    const headResponse = await fetchWorker("/fedora", { method: "HEAD" });
    expect(headResponse.status).toBe(getResponse.status);
    expect(await headResponse.text()).toBe("");
    expect(headResponse.headers.get("Content-Length")).toBe(
      String(new TextEncoder().encode(getBody).byteLength),
    );
    expect(headResponse.headers.get("X-Bootstrap-Version")).toBe(
      getResponse.headers.get("X-Bootstrap-Version"),
    );
  });
});
