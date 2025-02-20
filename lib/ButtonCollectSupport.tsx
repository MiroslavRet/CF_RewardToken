import { useWallet } from "../../contexts/wallet/WalletContext";
import { CampaignUTxO } from "../../contexts/campaign/CampaignContext";
import { collectSupport } from "../../crowdfunding";
import ActionButton from "../base/ActionButton";

import { Platform } from "@/types/platform";

export default function ButtonCollectSupport(props: {
  platform?: Platform;
  campaign: CampaignUTxO;
  onSuccess: (campaign: CampaignUTxO) => void;
  onError?: (error: any) => void;
}) {
  const { platform, campaign, onSuccess, onError } = props;

  const [walletConnection] = useWallet();

  return (
    <ActionButton
      actionLabel="Collect Support"
      buttonColor="primary"
      buttonVariant="flat"
      campaignAction={() => collectSupport(walletConnection, campaign, platform)}
      onError={onError}
      onSuccess={onSuccess}
    />
  );
}
