import { useEffect, useState } from "react";
import { Button } from "@nextui-org/button";
import {
  Modal,
  ModalBody,
  ModalContent,
  ModalFooter,
  ModalHeader,
  useDisclosure,
} from "@nextui-org/modal";
import { Spinner } from "@nextui-org/spinner";

import { handleError } from "@/components/utils";
import { finishMintBurn } from "@/components/crowdfunding";
import { useWallet } from "@/components/contexts/wallet/WalletContext";
import { CampaignUTxO } from "@/components/contexts/campaign/CampaignContext";

export default function ButtonFinishMintBurn(props: {
  campaign: CampaignUTxO;
  onSuccess: (updatedCampaign: CampaignUTxO) => void;
  onError?: (error: any) => void;
}) {
  const { campaign, onSuccess, onError } = props;

  const [walletConnection] = useWallet();
  const { isOpen, onOpen, onOpenChange } = useDisclosure();
  const [isSubmittingTx, setIsSubmittingTx] = useState(false);

  useEffect(() => {
    if (!isOpen) {
      setIsSubmittingTx(false);
    }
  }, [isOpen]);

  async function handleFinishMintBurn() {
    try {
      setIsSubmittingTx(true);
      const updatedCampaign = await finishMintBurn(walletConnection, campaign);
      onSuccess(updatedCampaign);
    } catch (err) {
      (onError ?? handleError)(err);
    } finally {
      onOpenChange(false);
    }
  }

  return (
    <>
      {/* Button that triggers the modal */}
      <Button
        color="primary"
        radius="full"
        variant="shadow"
        onPress={onOpen}
      >
        Finish & Mint Rewards
      </Button>

      {/* Confirmation Modal */}
      <Modal
        backdrop="blur"
        hideCloseButton={isSubmittingTx}
        isDismissable={!isSubmittingTx}
        isKeyboardDismissDisabled={isSubmittingTx}
        isOpen={isOpen}
        onOpenChange={onOpenChange}
        placement="top-center"
      >
        <ModalContent>
          {(onClose) => (
            <>
              <ModalHeader className="flex flex-col gap-1">
                Finish Campaign & Mint Rewards
              </ModalHeader>
              <ModalBody>
                Are you sure you want to finalize this campaign?
                <br />
                This will burn all support tokens and mint new reward tokens
                to distribute among backers.
              </ModalBody>
              <ModalFooter>
                {/* Cancel Button */}
                <div className="relative">
                  <Button
                    color="danger"
                    isDisabled={isSubmittingTx}
                    variant="flat"
                    onPress={onClose}
                  >
                    Cancel
                  </Button>
                </div>

                {/* Confirm Button */}
                <div className="relative">
                  <Button
                    className={isSubmittingTx ? "invisible" : ""}
                    color="primary"
                    variant="shadow"
                    onPress={handleFinishMintBurn}
                  >
                    Confirm
                  </Button>
                  {isSubmittingTx && (
                    <Spinner className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2" />
                  )}
                </div>
              </ModalFooter>
            </>
          )}
        </ModalContent>
      </Modal>
    </>
  );
}
