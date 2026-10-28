import { BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  AllDepositsDisabled,
  Deposit,
  FeeTiersSet,
  PoolAdded,
  PoolDepositsDisabled,
  Swept,
  Withdraw,
} from "../generated/RestakeRouterV1_0/RestakeRouter";
import {
  DailyPoolStats,
  DepositEvent,
  FeeTier,
  Pool,
  Position,
  ProtocolStats,
  Router,
  RouterPool,
  SweepEvent,
  User,
  WithdrawEvent,
} from "../generated/schema";

const ZERO = BigInt.zero();
const ONE = BigInt.fromI32(1);
const DAY = 86400;
const PROTOCOL_ID = "protocol";
const POOL_TYPES = ["NONE", "ERC4626", "AAVE_V3"];

// ───────────── Config (constructor) events ─────────────

export function handleFeeTiersSet(event: FeeTiersSet): void {
  const router = getRouter(event);
  const tiers = event.params.tiers;
  for (let i = 0; i < tiers.length; i++) {
    const tier = new FeeTier(router.id.toHexString() + "-" + i.toString());
    tier.router = router.id;
    tier.index = i;
    tier.minAmount = tiers[i].minAmount;
    tier.feeBps = tiers[i].feeBps;
    tier.save();
  }
}

export function handlePoolAdded(event: PoolAdded): void {
  const router = getRouter(event);
  const pool = getPool(event.params.pool, POOL_TYPES[event.params.poolType]);
  const listing = new RouterPool(routerPoolId(router.id, pool.id));
  listing.router = router.id;
  listing.pool = pool.id;
  listing.depositsDisabled = false;
  listing.addedAtBlock = event.block.number;
  listing.save();
}

// ───────────── Guardian ─────────────

export function handlePoolDepositsDisabled(event: PoolDepositsDisabled): void {
  const listing = RouterPool.load(routerPoolId(event.address, event.params.pool));
  if (listing == null) return;
  listing.depositsDisabled = true;
  listing.save();
}

export function handleAllDepositsDisabled(event: AllDepositsDisabled): void {
  const router = getRouter(event);
  router.allDepositsDisabled = true;
  router.save();
}

// ───────────── User flows ─────────────

export function handleDeposit(event: Deposit): void {
  const p = event.params;
  const router = getRouter(event);
  const pool = getPool(p.pool, "");
  const receiver = getUser(p.receiver);

  const entity = new DepositEvent(eventId(event));
  entity.router = router.id;
  entity.sender = p.sender;
  entity.receiver = receiver.id;
  entity.pool = pool.id;
  entity.asset = p.asset;
  entity.grossAssets = p.grossAssets;
  entity.fee = p.fee;
  entity.netAssets = p.netAssets;
  entity.shares = p.shares;
  entity.tierIndex = p.tierIndex;
  entity.feeBps = p.feeBps;
  entity.referralCode = p.referralCode;
  entity.blockNumber = event.block.number;
  entity.timestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();

  const position = getPosition(receiver.id, pool.id);
  position.shares = position.shares.plus(p.shares);
  position.netDeposited = position.netDeposited.plus(p.netAssets);
  position.feesPaid = position.feesPaid.plus(p.fee);
  position.updatedAtTimestamp = event.block.timestamp;
  position.save();

  router.depositCount = router.depositCount.plus(ONE);
  router.totalGrossDeposited = router.totalGrossDeposited.plus(p.grossAssets);
  router.totalFees = router.totalFees.plus(p.fee);
  router.save();

  pool.depositCount = pool.depositCount.plus(ONE);
  pool.totalNetDeposited = pool.totalNetDeposited.plus(p.netAssets);
  pool.totalFees = pool.totalFees.plus(p.fee);
  pool.save();

  const daily = getDailyPoolStats(pool.id, event.block.timestamp);
  daily.depositCount += 1;
  daily.grossDeposited = daily.grossDeposited.plus(p.grossAssets);
  daily.netDeposited = daily.netDeposited.plus(p.netAssets);
  daily.fees = daily.fees.plus(p.fee);
  daily.save();

  const stats = getProtocolStats();
  stats.depositCount = stats.depositCount.plus(ONE);
  stats.totalGrossDeposited = stats.totalGrossDeposited.plus(p.grossAssets);
  stats.totalFees = stats.totalFees.plus(p.fee);
  stats.save();
}

export function handleWithdraw(event: Withdraw): void {
  const p = event.params;
  const router = getRouter(event);
  const pool = getPool(p.pool, "");
  const sender = getUser(p.sender);

  const entity = new WithdrawEvent(eventId(event));
  entity.router = router.id;
  entity.sender = sender.id;
  entity.receiver = p.receiver;
  entity.pool = pool.id;
  entity.asset = p.asset;
  entity.shares = p.shares;
  entity.assets = p.assets;
  entity.blockNumber = event.block.number;
  entity.timestamp = event.block.timestamp;
  entity.transactionHash = event.transaction.hash;
  entity.save();

  // Router-flow only: shares obtained outside the router (or aToken interest) can push this below zero.
  const position = getPosition(sender.id, pool.id);
  const remaining = position.shares.minus(p.shares);
  position.shares = remaining.lt(ZERO) ? ZERO : remaining;
  position.withdrawn = position.withdrawn.plus(p.assets);
  position.updatedAtTimestamp = event.block.timestamp;
  position.save();

  router.withdrawCount = router.withdrawCount.plus(ONE);
  router.totalWithdrawn = router.totalWithdrawn.plus(p.assets);
  router.save();

  pool.withdrawCount = pool.withdrawCount.plus(ONE);
  pool.totalWithdrawn = pool.totalWithdrawn.plus(p.assets);
  pool.save();

  const daily = getDailyPoolStats(pool.id, event.block.timestamp);
  daily.withdrawCount += 1;
  daily.withdrawn = daily.withdrawn.plus(p.assets);
  daily.save();

  const stats = getProtocolStats();
  stats.withdrawCount = stats.withdrawCount.plus(ONE);
  stats.totalWithdrawn = stats.totalWithdrawn.plus(p.assets);
  stats.save();
}

export function handleSwept(event: Swept): void {
  const sweep = new SweepEvent(eventId(event));
  sweep.router = getRouter(event).id;
  sweep.token = event.params.token;
  sweep.amount = event.params.amount;
  sweep.timestamp = event.block.timestamp;
  sweep.save();
}

// ───────────── Loaders ─────────────

function eventId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}

function routerPoolId(router: Bytes, pool: Bytes): string {
  return router.toHexString() + "-" + pool.toHexString();
}

function getRouter(event: ethereum.Event): Router {
  let router = Router.load(event.address);
  if (router == null) {
    router = new Router(event.address);
    router.allDepositsDisabled = false;
    router.depositCount = ZERO;
    router.withdrawCount = ZERO;
    router.totalGrossDeposited = ZERO;
    router.totalFees = ZERO;
    router.totalWithdrawn = ZERO;
    router.deployedAtBlock = event.block.number;
    router.deployedAtTimestamp = event.block.timestamp;
    router.save();

    const stats = getProtocolStats();
    stats.routerCount += 1;
    stats.save();
  }
  return router;
}

/// @param poolType Set when first seen via PoolAdded; "" when loading from a user event.
function getPool(address: Bytes, poolType: string): Pool {
  let pool = Pool.load(address);
  if (pool == null) {
    pool = new Pool(address);
    pool.poolType = poolType;
    pool.depositCount = ZERO;
    pool.withdrawCount = ZERO;
    pool.totalNetDeposited = ZERO;
    pool.totalWithdrawn = ZERO;
    pool.totalFees = ZERO;
    pool.save();
  }
  return pool;
}

function getUser(address: Bytes): User {
  let user = User.load(address);
  if (user == null) {
    user = new User(address);
    user.save();

    const stats = getProtocolStats();
    stats.userCount += 1;
    stats.save();
  }
  return user;
}

function getPosition(user: Bytes, pool: Bytes): Position {
  const id = user.toHexString() + "-" + pool.toHexString();
  let position = Position.load(id);
  if (position == null) {
    position = new Position(id);
    position.user = user;
    position.pool = pool;
    position.shares = ZERO;
    position.netDeposited = ZERO;
    position.feesPaid = ZERO;
    position.withdrawn = ZERO;
    position.updatedAtTimestamp = ZERO;
  }
  return position;
}

function getDailyPoolStats(pool: Bytes, timestamp: BigInt): DailyPoolStats {
  const day = timestamp.toI32() / DAY;
  const id = pool.toHexString() + "-" + day.toString();
  let daily = DailyPoolStats.load(id);
  if (daily == null) {
    daily = new DailyPoolStats(id);
    daily.pool = pool;
    daily.dayStartTimestamp = BigInt.fromI32(day * DAY);
    daily.depositCount = 0;
    daily.withdrawCount = 0;
    daily.grossDeposited = ZERO;
    daily.netDeposited = ZERO;
    daily.fees = ZERO;
    daily.withdrawn = ZERO;
  }
  return daily;
}

function getProtocolStats(): ProtocolStats {
  let stats = ProtocolStats.load(PROTOCOL_ID);
  if (stats == null) {
    stats = new ProtocolStats(PROTOCOL_ID);
    stats.routerCount = 0;
    stats.userCount = 0;
    stats.depositCount = ZERO;
    stats.withdrawCount = ZERO;
    stats.totalGrossDeposited = ZERO;
    stats.totalFees = ZERO;
    stats.totalWithdrawn = ZERO;
  }
  return stats;
}
