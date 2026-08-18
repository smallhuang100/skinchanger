/**
 * Rivals Skin Changer · HWID 封鎖 API（Cloudflare Worker + Workers KV）
 * ---------------------------------------------------------------------------
 * 端點：
 *
 *   GET  /check?hwid=X                  查詢是否被封鎖，公開查詢，不需要 secret
 *   POST /report  { hwid, secret, reason }   把 hwid 加入封鎖名單，需要 secret
 *   POST /unban   { hwid, secret }           把 hwid 移出封鎖名單，需要 secret
 *   GET  /list?secret=X                       列出目前所有被封鎖的 hwid，需要 secret
 *
 * 需要在 Worker 設定裡綁定一個叫 HWID_BANS 的 KV Namespace。
 * 完整步驟看同一個資料夾裡的 HWID_BAN_SETUP.md。
 * ---------------------------------------------------------------------------
 */

// ⚠️ 這組是幫你先隨機產生好的，跟 SkinChanger.luau 裡的 REPORT_SECRET 要完全一樣。
// 想換掉也可以，兩邊改成同一組新字串就好。這組 secret 只是用來擋「不相干的人
// 亂呼叫 /report、/unban、/list」，不是萬能保護——如果腳本本身被整份反混淆，
// 這組字串本來就會跟著被看到，這是 client 端內嵌密鑰的先天限制，不是這份
// Worker 的 bug。
const BAN_SECRET = "a07e18c7510588f04dea5774077d7d434bdcc864c3a1f1e4";

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

async function readJsonBody(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // --- 查詢是否被封鎖（公開，任何人都能查自己的 hwid 狀態） -------------
    if (url.pathname === "/check" && request.method === "GET") {
      const hwid = url.searchParams.get("hwid");
      if (!hwid) return json({ error: "missing hwid" }, 400);

      const raw = await env.HWID_BANS.get(hwid);
      if (!raw) return json({ banned: false });

      let record;
      try {
        record = JSON.parse(raw);
      } catch {
        record = { reason: "unknown" };
      }

      return json({ banned: true, reason: record.reason, at: record.at });
    }

    // --- 新增封鎖（腳本偵測到 hook 痕跡時呼叫） -----------------------------
    if (url.pathname === "/report" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (!body) return json({ error: "bad json" }, 400);
      if (body.secret !== BAN_SECRET) return json({ error: "unauthorized" }, 401);
      if (!body.hwid) return json({ error: "missing hwid" }, 400);

      await env.HWID_BANS.put(
        body.hwid,
        JSON.stringify({
          reason: body.reason || "unspecified",
          at: new Date().toISOString(),
        })
      );

      return json({ ok: true });
    }

    // --- 解除封鎖（誤判復原用，一定要留這個端點） ---------------------------
    if (url.pathname === "/unban" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (!body) return json({ error: "bad json" }, 400);
      if (body.secret !== BAN_SECRET) return json({ error: "unauthorized" }, 401);
      if (!body.hwid) return json({ error: "missing hwid" }, 400);

      await env.HWID_BANS.delete(body.hwid);
      return json({ ok: true });
    }

    // --- 列出所有封鎖（管理用） ----------------------------------------------
    if (url.pathname === "/list" && request.method === "GET") {
      if (url.searchParams.get("secret") !== BAN_SECRET) {
        return json({ error: "unauthorized" }, 401);
      }

      const list = await env.HWID_BANS.list();
      const results = [];

      for (const key of list.keys) {
        const raw = await env.HWID_BANS.get(key.name);
        let record;
        try {
          record = JSON.parse(raw);
        } catch {
          record = { reason: "unknown" };
        }
        results.push({ hwid: key.name, ...record });
      }

      return json({ count: results.length, bans: results });
    }

    return json({ error: "not found" }, 404);
  },
};
