// Deploys _site to Deno Deploy.
//
// Deploy's uploader skips git-ignored paths, and _site is ignored, so the
// built site is staged in a temp directory outside the repository and
// uploaded from there.

const APP = "atoll-docs";
const ORG = "tsirysndr";
const SITE_URL = Deno.env.get("SITE_URL") ?? `https://${APP}.${ORG}.deno.net/`;

const run = async (cmd: string[], cwd?: string, env?: Record<string, string>) => {
  const { code } = await new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    cwd,
    env,
    stdout: "inherit",
    stderr: "inherit",
  }).output();
  if (code !== 0) Deno.exit(code);
};

await run(["deno", "task", "build"], undefined, { ...Deno.env.toObject(), SITE_URL });

const stage = await Deno.makeTempDir({ prefix: `${APP}-` });
await Deno.mkdir(`${stage}/_site`, { recursive: true });
await run(["cp", "-R", "_site/.", `${stage}/_site`]);
await Deno.writeTextFile(
  `${stage}/deno.json`,
  JSON.stringify({ deploy: { org: ORG, app: APP } }, null, 2) + "\n",
);

await run(["deno", "deploy", "--prod", ...Deno.args], stage);
await Deno.remove(stage, { recursive: true });
