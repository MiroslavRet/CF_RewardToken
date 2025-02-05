import { fromText } from "@lucid-evolution/lucid";

const assetName = "STATE_TOKEN";
const assetREWARDName = "REWARD_TOKEN";

export const STATE_TOKEN = { assetName, hex: fromText(assetName) };
export const REWARD_TOKEN = { assetREWARDName, hex: fromText(assetREWARDName) };