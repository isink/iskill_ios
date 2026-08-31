import { applyOverrides } from "./lib/overrides";

applyOverrides({ strict: true }).catch((error) => {
  console.error("✖ Final override application failed:");
  console.error(error);
  process.exit(1);
});
