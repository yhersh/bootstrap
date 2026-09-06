export const BOOTSTRAP_VERSION = "1.0.0";

import fedoraScript from "../scripts/fedora.sh";
import macosScript from "../scripts/macos.sh";
import windowsScript from "../scripts/windows.ps1";
import releaseManifest from "../releases/manifest.json";

const CACHE_MOVING = "public, max-age=300";
const CACHE_IMMUTABLE = "public, max-age=31536000, immutable";
const CACHE_NONE = "no-store";

const SECURITY_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'",
  "X-Bootstrap-Version": BOOTSTRAP_VERSION,
};

type ScriptPayload = {
  body: string;
  cacheControl: string;
};

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function scriptHeaders(cacheControl: string): Headers {
  const headers = new Headers({
    "Content-Type": "text/plain; charset=utf-8",
    "Cache-Control": cacheControl,
    ...SECURITY_HEADERS,
  });
  return headers;
}

function textResponse(
  body: string,
  status = 200,
  cacheControl = CACHE_MOVING,
): Response {
  return new Response(body, {
    status,
    headers: scriptHeaders(cacheControl),
  });
}

function methodNotAllowed(): Response {
  return new Response("Method Not Allowed", {
    status: 405,
    headers: {
      Allow: "GET, HEAD",
      "Content-Type": "text/plain; charset=utf-8",
      ...SECURITY_HEADERS,
    },
  });
}

function notFound(): Response {
  return new Response("Not Found", {
    status: 404,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": CACHE_NONE,
      ...SECURITY_HEADERS,
    },
  });
}

function usageText(): string {
  return [
    "bootstrap.yaronhersh.xyz",
    "",
    `Version: ${BOOTSTRAP_VERSION}`,
    "",
    "Fedora:",
    "  curl -fsSL https://bootstrap.yaronhersh.xyz/fedora | bash",
    "",
    "macOS:",
    "  curl -fsSL https://bootstrap.yaronhersh.xyz/macos | bash",
    "",
    "Windows (Administrator PowerShell):",
    "  irm https://bootstrap.yaronhersh.xyz/windows | iex",
    "",
    "Routes:",
    "  /fedora                 current stable Fedora script",
    "  /fedora/v1              current stable within major v1",
    `  /fedora/v${BOOTSTRAP_VERSION}       immutable Fedora script`,
    `  /fedora/v${BOOTSTRAP_VERSION}.sha256  Fedora script checksum`,
    "  /macos                  current stable macOS script",
    "  /macos/v1               current stable within major v1",
    `  /macos/v${BOOTSTRAP_VERSION}        immutable macOS script`,
    `  /macos/v${BOOTSTRAP_VERSION}.sha256   macOS script checksum`,
    "  /windows                current stable Windows script",
    "  /releases/manifest.json release manifest",
    "  /healthz                build and release metadata",
    "",
    "Source: https://github.com/yhersh/bootstrap",
  ].join("\n");
}

function healthText(buildTimestamp: string): string {
  return JSON.stringify(
    {
      status: "ok",
      version: BOOTSTRAP_VERSION,
      buildTimestamp,
      manifest: releaseManifest,
    },
    null,
    2,
  );
}

function resolveRoute(pathname: string): ScriptPayload | "usage" | "health" | "manifest" | { kind: "checksum"; script: string; filename: string } | null {
  switch (pathname) {
    case "/":
      return "usage";
    case "/health":
    case "/healthz":
      return "health";
    case "/releases/manifest.json":
      return "manifest";
    case "/fedora":
    case "/fedora/v1":
    case `/fedora/v${BOOTSTRAP_VERSION}`:
      return { body: fedoraScript, cacheControl: pathname.endsWith(BOOTSTRAP_VERSION) ? CACHE_IMMUTABLE : CACHE_MOVING };
    case `/fedora/v${BOOTSTRAP_VERSION}.sha256`:
      return { kind: "checksum", script: fedoraScript, filename: "fedora.sh" };
    case "/macos":
    case "/macos/v1":
    case `/macos/v${BOOTSTRAP_VERSION}`:
      return { body: macosScript, cacheControl: pathname.endsWith(BOOTSTRAP_VERSION) ? CACHE_IMMUTABLE : CACHE_MOVING };
    case `/macos/v${BOOTSTRAP_VERSION}.sha256`:
      return { kind: "checksum", script: macosScript, filename: "macos.sh" };
    case "/windows":
      return { body: windowsScript, cacheControl: CACHE_MOVING };
    default:
      return null;
  }
}

async function handleGetOrHead(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const resolved = resolveRoute(url.pathname);

  if (resolved === null) {
    return notFound();
  }

  if (resolved === "usage") {
    const body = usageText();
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: {
          ...Object.fromEntries(scriptHeaders(CACHE_MOVING)),
          "Content-Length": String(new TextEncoder().encode(body).byteLength),
        },
      });
    }
    return textResponse(body, 200, CACHE_MOVING);
  }

  if (resolved === "health") {
    const buildTimestamp = env.BUILD_TIMESTAMP ?? "unknown";
    const body = healthText(buildTimestamp);
    const headers = {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": CACHE_NONE,
      ...SECURITY_HEADERS,
    };
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: {
          ...headers,
          "Content-Length": String(new TextEncoder().encode(body).byteLength),
        },
      });
    }
    return new Response(body, { status: 200, headers });
  }

  if (resolved === "manifest") {
    const body = JSON.stringify(releaseManifest, null, 2) + "\n";
    const headers = {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": CACHE_MOVING,
      ...SECURITY_HEADERS,
    };
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: {
          ...headers,
          "Content-Length": String(new TextEncoder().encode(body).byteLength),
        },
      });
    }
    return new Response(body, { status: 200, headers });
  }

  if (resolved !== null && typeof resolved === "object" && "kind" in resolved && resolved.kind === "checksum") {
    const digest = await sha256Hex(resolved.script);
    const body = `${digest}  ${resolved.filename}\n`;
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: {
          ...Object.fromEntries(scriptHeaders(CACHE_IMMUTABLE)),
          "Content-Length": String(new TextEncoder().encode(body).byteLength),
        },
      });
    }
    return textResponse(body, 200, CACHE_IMMUTABLE);
  }

  if (typeof resolved === "object" && resolved !== null && "body" in resolved) {
    const { body, cacheControl } = resolved;
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 200,
        headers: {
          ...Object.fromEntries(scriptHeaders(cacheControl)),
          "Content-Length": String(new TextEncoder().encode(body).byteLength),
        },
      });
    }
    return textResponse(body, 200, cacheControl);
  }

  return notFound();
}

export interface Env {
  BUILD_TIMESTAMP?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return methodNotAllowed();
    }
    return handleGetOrHead(request, env);
  },
};
