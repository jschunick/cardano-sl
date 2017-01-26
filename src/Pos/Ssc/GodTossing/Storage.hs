{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Instance of SscStorageClass.

module Pos.Ssc.GodTossing.Storage
       ( -- * Instances
         -- ** instance SscStorageClass SscGodTossing
         getGlobalCerts
       , gtGetGlobalState
       , getStableCerts
       ) where

import           Control.Lens                   (to, (%=), (.=), (<>=))
import           Control.Monad.Reader           (ask)
import           Data.Default                   (def)
import qualified Data.HashMap.Strict            as HM
import qualified Data.HashSet                   as HS
import qualified Data.List.NonEmpty             as NE
import           Formatting                     (sformat, (%))
import           Serokell.Util.Text             (listJson)
import           Serokell.Util.Verify           (VerificationRes (..), isVerSuccess,
                                                 verifyGeneric)
import           System.Wlog                    (WithLogger, logDebug)
import           Universum

import           Pos.Binary.Ssc                 ()
import           Pos.Constants                  (epochSlots, vssMaxTTL)
import           Pos.DB                         (DBError (DBMalformed), MonadDB,
                                                 getBlockHeader, loadBlocksWhile)
import           Pos.Lrc.Types                  (Richmen)
import           Pos.Ssc.Class.Storage          (SscStorageClass (..))
import           Pos.Ssc.Class.Types            (Ssc (..))
import           Pos.Ssc.Extra.MonadGS          (MonadSscGS (..), sscRunGlobalQuery)
import           Pos.Ssc.GodTossing.Error       (SeedError)
import           Pos.Ssc.GodTossing.Functions   (checkCommShares,
                                                 checkOpeningMatchesCommitment,
                                                 checkShares, computeParticipants,
                                                 isCommitmentIdx, isOpeningIdx,
                                                 isSharesIdx, verifyGtPayload)
import           Pos.Ssc.GodTossing.Genesis     (genesisCertificates)
import           Pos.Ssc.GodTossing.Seed        (calculateSeed)
import           Pos.Ssc.GodTossing.Types       (GtGlobalState (..), GtPayload (..),
                                                 SscGodTossing, VssCertificatesMap,
                                                 gsCommitments, gsOpenings, gsShares,
                                                 gsVssCertificates, vcVssKey,
                                                 _gpCertificates)
import           Pos.Ssc.GodTossing.Types.Base  (VssCertificate (..))
import qualified Pos.Ssc.GodTossing.VssCertData as VCD
import           Pos.Types                      (Block, EpochIndex (..), EpochOrSlot (..),
                                                 HeaderHash, SharedSeed, SlotId (..),
                                                 addressHash, blockMpc, blockSlot,
                                                 crucialSlot, epochIndexL, epochOrSlot,
                                                 epochOrSlotG, gbHeader)
import           Pos.Util                       (NE, NewestFirst (..), OldestFirst)

type GSQuery a  = forall m . (MonadReader GtGlobalState m, WithLogger m) => m a
type GSUpdate a = forall m . (MonadState GtGlobalState m) => m a

instance SscStorageClass SscGodTossing where
    sscLoadGlobalState = mpcLoadGlobalState
    sscApplyBlocksM = mpcApplyBlocks
    sscRollbackM = mpcRollback
    sscVerifyBlocksM = mpcVerifyBlocks
    sscCalculateSeedM = calculateSeedQ

gtGetGlobalState
    :: (MonadSscGS SscGodTossing m)
    => m GtGlobalState
gtGetGlobalState = sscRunGlobalQuery ask

getGlobalCerts
    :: (MonadSscGS SscGodTossing m)
    => SlotId -> m VssCertificatesMap
getGlobalCerts sl =
    sscRunGlobalQuery $
        VCD.certs .
        VCD.setLastKnownSlot sl <$>
        view (gsVssCertificates)

getStablePure :: EpochIndex -> VCD.VssCertData -> VssCertificatesMap
getStablePure epoch certs
    | epoch == 0 = genesisCertificates
    | otherwise =
          VCD.certs $ VCD.setLastKnownSlot (crucialSlot epoch) certs

-- | Verified certs for slotId
getStableCerts :: MonadSscGS SscGodTossing m => EpochIndex -> m VssCertificatesMap
getStableCerts epoch =
    getStablePure epoch <$> sscRunGlobalQuery (view gsVssCertificates)

-- | Verify that if one adds given block to the current chain, it will
-- remain consistent with respect to SSC-related data.
mpcVerifyBlock :: Bool -> Richmen -> Block SscGodTossing -> GSQuery VerificationRes
-- Genesis blocks don't have any SSC data.
mpcVerifyBlock _ _ (Left _) = return VerSuccess
-- Main blocks have commitments, openings, shares and VSS
-- certificates.  We optionally (depending on verifyPure argument) use
-- verifyGtPayload to make the most general checks and also use global
-- data to make more checks using this data.
mpcVerifyBlock verifyPure richmen (Right b) = do
    let SlotId{siSlot = slotId} = b ^. blockSlot
        payload      = b ^. blockMpc
        curEpoch = siEpoch $ b ^. blockSlot
        blockCerts = _gpCertificates payload
        richmenSet = HS.fromList $ NE.toList richmen

    globalCommitments <- view gsCommitments
    globalOpenings    <- view gsOpenings
    globalShares      <- view gsShares
    globalVCD         <- view gsVssCertificates
    let globalCerts   = VCD.certs globalVCD
    let stableCerts   = getStablePure curEpoch globalVCD
    let participants  = computeParticipants richmen stableCerts
    let participantsVssKeys = map vcVssKey $ toList participants

    let isComm  = (isCommitmentIdx slotId, "slotId doesn't belong commitment phase")
        isOpen  = (isOpeningIdx slotId, "slotId doesn't belong openings phase")
        isShare = (isSharesIdx slotId, "slotId doesn't belong share phase")

    -- For commitments we
    --   * check that the nodes haven't already sent their commitments before
    --     in some different block
    --   * check that a VSS certificate is present for the committing nodeg
    --   * every commitment owner has enough (mpc+delegated) stake
    let commChecks comms =
            [ isComm
            , (all (`HM.member` participants)
                   (HM.keys comms),
                   "some committing nodes haven't sent a VSS certificate")
            , (all (not . (`HM.member` globalCommitments))
                   (HM.keys comms),
                   "some nodes have already sent their commitments")
            , (all (checkCommShares participantsVssKeys) (toList comms),
                   "some commShares has been generated on wrong participants")
            -- [CSL-206]: check that share IDs are different.
            ]

    -- For openings, we check that
    --   * the opening isn't present in previous blocks
    --   * corresponding commitment is present
    --   * the opening matches the commitment
    let openChecks opens =
            [ isOpen
            , (all (not . (`HM.member` globalOpenings))
                   (HM.keys opens),
                   "some nodes have already sent their openings")
            , (all (`HM.member` globalCommitments) (HM.keys opens),
                   "some openings don't have corresponding commitments")
            , (all (checkOpeningMatchesCommitment globalCommitments) (HM.toList opens),
                   "some openings don't match corresponding commitments")
            ]

    -- For shares, we check that
    --   * shares have corresponding commitments
    --   * these shares weren't sent before
    --   * if encrypted shares (in commitments) are decrypted, they match
    --     decrypted shares
    -- We don't check whether shares match the openings.
    let shareChecks shares =
            [ isShare
            -- We intentionally don't check, that nodes which decrypted shares
            -- sent its commitments.
            -- If node decrypted shares correctly, such node is useful for us, despite of
            -- it didn't send its commitment.
            , (all (`HS.member` richmenSet) $ HM.keys shares,
                   "some shares are posted by stakeholders that don't have enough stake")
            , (all (`HM.member` globalCommitments)
                   (concatMap HM.keys $ toList shares),
                   "some shares don't have corresponding commitments")
            , (null (shares `HM.intersection` globalShares),
                   "some shares have already been sent")
            , (all (uncurry (checkShares globalCommitments globalOpenings participants))
                   (HM.toList shares),
                   "some decrypted shares don't match encrypted shares \
                   \in the corresponding commitment")
            ]

    let certChecks certs =
            [
              (all (maybe True ((==) curEpoch . vcExpiryEpoch) . (`HM.lookup` globalCerts))
                   (HM.keys certs),
                   "some VSS certificates have been resubmitted \
                   \earlier than expiry epoch")
            , (all ((`HS.member` richmenSet) . addressHash . vcSigningKey)
                   (HM.elems certs),
                   "some VSS certificates' users are not passing stake threshold")
            ]


    let ourRes = verifyGeneric $ certChecks blockCerts ++
            case payload of
                CommitmentsPayload comms _     -> commChecks comms
                OpeningsPayload        opens _ -> openChecks opens
                SharesPayload         shares _ -> shareChecks shares
                CertificatesPayload          _ -> []

    case ourRes of
        VerSuccess -> return ()
        _          -> logDebug $ sformat
                        ("Richmen = " % listJson % ", certs = " %listJson% ", GT participants = " %listJson)
                        richmen (HM.keys globalCerts) (HM.keys participants)

    let pureRes = if verifyPure
                  then verifyGtPayload (b ^. gbHeader) payload
                  else mempty
    return (pureRes <> ourRes)

-- TODO:
--   ★ verification messages should include block hash/slotId
--   ★ we should stop at first failing block
mpcVerifyBlocks
    :: Bool
    -> Richmen
    -> OldestFirst NE (Block SscGodTossing)
    -> GSQuery VerificationRes
mpcVerifyBlocks verifyPure richmen blocks = do
    curState <- ask
    flip evalStateT curState $ do
        vs <- forM blocks $ \b -> do
            v <- mpcVerifyBlock verifyPure richmen b
            when (isVerSuccess v) $
                mpcProcessBlock b
            return v
        return $ fold vs

-- | Apply sequence of blocks to state. Sequence must be based on last
-- applied block and must be valid.
mpcApplyBlocks :: OldestFirst NE (Block SscGodTossing) -> GSUpdate ()
mpcApplyBlocks = mapM_ mpcProcessBlock

mpcProcessBlock
    :: (SscPayload ssc ~ GtPayload)
    => Block ssc -> GSUpdate ()
mpcProcessBlock blk = do
    let eos = blk ^. epochOrSlotG
    gsVssCertificates %= VCD.setLastKnownEoS eos
    case blk of
        -- Genesis blocks don't contain anything interesting, but when they
        -- “arrive”, we clear global commitments and other globals. Not
        -- certificates, though, because we don't want to make nodes resend
        -- them in each epoch.
        Left _  -> resetGS
        -- Main blocks contain commitments, openings, shares, VSS certificates
        Right b -> modify (unionPayload (b ^. blockMpc))

mpcRollback :: NewestFirst NE (Block SscGodTossing) -> GSUpdate ()
mpcRollback (NewestFirst blocks) = do
    -- Rollback certs
    let eos = (NE.last blocks) ^. epochOrSlotG
    rollbackCerts eos
    -- Rollback other payload
    wasGenesis <- foldM foldStep False blocks
    when wasGenesis resetGS
  where
    foldStep wasGen b
        | wasGen = pure wasGen
        | otherwise = differenceBlock b

    rollbackCerts :: EpochOrSlot -> GSUpdate ()
    rollbackCerts (EpochOrSlot (Left (EpochIndex 0))) =
        gsVssCertificates .= unionCerts genesisCertificates
    rollbackCerts (EpochOrSlot (Left ei)) =
        gsVssCertificates %= VCD.setLastKnownSlot (SlotId (ei - 1) (epochSlots - 1))
    rollbackCerts (EpochOrSlot (Right (SlotId e 0))) =
        gsVssCertificates %= VCD.setLastKnownEoS (EpochOrSlot $ Left e)
    rollbackCerts (EpochOrSlot (Right (SlotId e s))) =
        gsVssCertificates %= VCD.setLastKnownSlot (SlotId e (s - 1))

    differenceBlock :: Block SscGodTossing -> GSUpdate Bool
    differenceBlock (Left _) = pure True
    differenceBlock (Right b) = do
        let payload = b ^. blockMpc
        case payload of
            CommitmentsPayload comms _ ->
                gsCommitments %= (`HM.difference` comms)
            OpeningsPayload opens _ -> gsOpenings %= (`HM.difference` opens)
            SharesPayload shares _ -> gsShares %= (`HM.difference` shares)
            CertificatesPayload _ -> return ()
        pure False
    unionCerts = (foldl' (flip $ uncurry VCD.insert)) VCD.empty . HM.toList

-- | Calculate leaders for the next epoch.
calculateSeedQ :: EpochIndex -> GSQuery (Either SeedError SharedSeed)
calculateSeedQ _ =
    calculateSeed <$> view gsCommitments <*> view gsOpenings <*>
        view gsShares

mpcLoadGlobalState :: MonadDB SscGodTossing m => HeaderHash -> m GtGlobalState
mpcLoadGlobalState tip = do
    bh <- getBlockHeader tip
    endEpoch <-
          epochOrSlot identity siEpoch <$>
            maybe (throwM $ DBMalformed "No block header with tip")
                  (pure . view epochOrSlotG) bh
    let startEpoch = safeSub endEpoch -- load blocks while >= endEpoch
        whileEpoch b = b ^. epochIndexL >= startEpoch
    blocks <- loadBlocksWhile whileEpoch tip
    let global' = unionBlocks blocks
        global = global'
            & gsVssCertificates %~ unionBlksCerts (reverse (getNewestFirst blocks))
    pure $ if | startEpoch == 0 ->
                   over gsVssCertificates unionGenCerts global
              | otherwise -> global
  where
    setLastKnownEoS (EpochOrSlot eos) vcd
        | Left e <- eos, e == 0 = VCD.empty
        | Left e <- eos = VCD.setLastKnownSlot (SlotId (e - 1) (epochSlots - 1)) vcd
        | Right s <- eos = VCD.setLastKnownSlot s vcd
    safeSub epoch = epoch - min epoch vssMaxTTL
    unionBlckCert vcd block =
        let blkCert = either (const mempty) (^. blockMpc . to _gpCertificates)
            res = foldl' (flip $ uncurry VCD.insert) vcd . HM.toList $ (blkCert block) in
        setLastKnownEoS (block ^. epochOrSlotG) res
    unionBlksCerts blocks gs = foldl' unionBlckCert gs blocks
    unionGenCerts gs = foldl' (flip $ uncurry VCD.insert) gs . HM.toList $ genesisCertificates

----------------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------------
resetGS :: GSUpdate ()
resetGS = do
    gsCommitments .= mempty
    gsOpenings    .= mempty
    gsShares      .= mempty

unionPayload :: GtPayload -> GtGlobalState -> GtGlobalState
unionPayload payload gs =
    flip execState gs $ do
        case payload of
            CommitmentsPayload comms _ -> gsCommitments <>= comms
            OpeningsPayload opens _    -> gsOpenings <>= opens
            SharesPayload shares _     -> gsShares <>= shares
            CertificatesPayload _      -> pure ()

-- | Union payloads of blocks until meet genesis block
-- Invalid restore of VSS certificates
unionBlocks :: NewestFirst [] (Block SscGodTossing) -> GtGlobalState
unionBlocks (NewestFirst [])            = def
unionBlocks (NewestFirst (Left _:_))    = def
unionBlocks (NewestFirst (Right mb:xs)) =
    unionPayload (mb ^. blockMpc) $ unionBlocks $ NewestFirst xs
