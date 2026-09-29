/**
 * Perpl perp leg: open the perp this swap hedges, from the passkey wallet.
 *
 * Perpl is a fully on-chain order book, so there is no API key and no
 * off-chain signature: an order is a plain `execOrder` call to the Exchange
 * contract, signed by the same passkey-derived EOA that trades on PREMIA.
 * ABI and field scaling follow PerplFoundation/dex-sdk (abi/dex/Exchange.json,
 * types/request.rs).
 */
import { parseAbi, type LocalAccount, type PublicClient, type WalletClient } from "viem";

export const PERPL_EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F" as const;

export const perplAbi = parseAbi([
  "function createAccount(uint256 amountCNS) returns (uint256 accountId)",
  "function getMinAccountOpenCNS() view returns (uint256)",
  "function execOrder((uint256 orderDescId,uint256 perpId,uint8 orderType,uint256 orderId,uint256 pricePNS,uint256 lotLNS,uint256 expiryBlock,bool postOnly,bool fillOrKill,bool immediateOrCancel,uint256 maxMatches,uint256 leverageHdths,uint256 lastExecutionBlock,uint256 amountCNS,uint256 maxNegPnlCollatBPS) orderDesc) returns ((uint256 perpId,uint256 orderId) signature)",
  "function getAccountByAddr(address accountAddress) view returns ((uint256 accountId,uint256 balanceCNS,uint256 lockedBalanceCNS,uint8 frozen,address accountAddr,(uint256 bank1,uint256 bank2,uint256 bank3,uint256 bank4) positions) accountInfo)",
  "function getPositionV2(uint256 perpId,uint256 accountId) view returns ((uint256 accountId,uint256 nextNodeId,uint256 prevNodeId,uint8 positionType,uint256 depositCNS,uint256 pricePNS,uint256 lotLNS,uint256 entryBlock,int256 pnlCNS,int256 deltaPnlCNS,int256 premiumPnlCNS,uint256 priceResiduePNSQ16) positionInfo,uint256 markPricePNS,bool markPriceValid)",
  "function getPerpetualInfoV2(uint256 perpId) view returns ((string name,string symbol,uint256 priceDecimals,uint256 lotDecimals,bytes32 linkFeedId,uint256 priceTolPer100K,uint256 marginTol,uint256 marginTolDecimals,uint256 refPriceMaxAgeSec,uint256 positionBalanceCNS,uint256 insuranceBalanceCNS,uint256 markPNS,uint256 markTimestamp,uint256 lastPNS,uint256 lastTimestamp,uint256 oraclePNS,uint256 oracleTimestampSec,uint256 longOpenInterestLNS,uint256 shortOpenInterestLNS,uint256 fundingStartBlock,int16 fundingRatePct100k,uint256 absFundingClampPctPer100K,uint8 status,uint256 basePricePNS,uint256 maxBidPriceONS,uint256 minBidPriceONS,uint256 maxAskPriceONS,uint256 minAskPriceONS,uint256 numOrders,bool ignOracle,uint256 fundingSumScalingExp) perpetualInfo)",
]);

const erc20 = parseAbi([
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);

export const OPEN_LONG = 0;
export const OPEN_SHORT = 1;

/** Perpl account id for this wallet, or null if it has never deposited. */
export async function perplAccountId(pc: PublicClient, addr: `0x${string}`): Promise<bigint | null> {
  try {
    const a = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "getAccountByAddr", args: [addr] });
    return a.accountId > 0n ? a.accountId : null;
  } catch {
    return null; // the exchange reverts for unknown addresses
  }
}

async function send(pc: PublicClient, wc: WalletClient, account: LocalAccount, req: any) {
  const hash = await wc.writeContract({ ...req, account, chain: wc.chain });
  const r = await pc.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted: ${hash}`);
  return hash;
}

/**
 * Open (or add to) a perp position with an immediate-or-cancel order that
 * crosses the book up to `slippageBps` past the best price. Creates the
 * Perpl account on first use with `depositCNS` of collateral.
 */
export async function openPerp(opts: {
  pc: PublicClient; wc: WalletClient; account: LocalAccount; collateral: `0x${string}`;
  perpId: number; long: boolean; lotLNS: bigint; leverage: number;
  depositCNS: bigint; slippageBps?: number;
}) {
  const { pc, wc, account, collateral, perpId, long, lotLNS, leverage, depositCNS } = opts;
  const slip = BigInt(opts.slippageBps ?? 50);
  const hashes: string[] = [];

  let accountId = await perplAccountId(pc, account.address);
  if (accountId === null) {
    const allowance = await pc.readContract({ address: collateral, abi: erc20,
      functionName: "allowance", args: [account.address, PERPL_EXCHANGE] });
    if (allowance < depositCNS) {
      hashes.push(await send(pc, wc, account, { address: collateral, abi: erc20,
        functionName: "approve", args: [PERPL_EXCHANGE, depositCNS] }));
    }
    hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "createAccount", args: [depositCNS] }));
    accountId = await perplAccountId(pc, account.address);
    if (accountId === null) throw new Error("Perpl account was not created");
  }

  const info = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getPerpetualInfoV2", args: [BigInt(perpId)] });
  // ONS = PNS - basePricePNS; best ask for a buy, best bid for a sell.
  const best = (long ? info.minAskPriceONS : info.maxBidPriceONS) + info.basePricePNS;
  if (best === 0n) throw new Error("empty book");
  const limit = long ? best * (10_000n + slip) / 10_000n : best * (10_000n - slip) / 10_000n;

  hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "execOrder", args: [{
      orderDescId: BigInt(Date.now() % 1_000_000_000),
      perpId: BigInt(perpId),
      orderType: long ? OPEN_LONG : OPEN_SHORT,
      orderId: 0n,
      pricePNS: limit,
      lotLNS,
      expiryBlock: 0n,
      postOnly: false,
      fillOrKill: false,
      immediateOrCancel: true,
      maxMatches: 100n,
      leverageHdths: BigInt(Math.round(leverage * 100)),
      lastExecutionBlock: 0n,
      amountCNS: 0n,
      maxNegPnlCollatBPS: 1000n,
    }] }));

  const pos = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getPositionV2", args: [BigInt(perpId), accountId] });
  return { accountId, hashes, position: pos[0], markPNS: pos[1], limitPNS: limit };
}
