import { describe, it, expect } from "vitest";
import { Cl, cvToValue } from "@stacks/transactions";

// The `simnet` global is provided by vitest-environment-clarinet (see vitest.config.js)

const CONTRACT = "niche-cleaning-service";

function getAccounts() {
  const accounts = simnet.getAccounts();
  const deployer = accounts.get("deployer");
  const provider = accounts.get("wallet_1");
  const customer = accounts.get("wallet_2");
  if (!deployer || !provider || !customer) {
    throw new Error("Missing expected simnet accounts");
  }
  return { deployer, provider, customer };
}

describe("Niche Cleaning Service - liquidity", () => {
  it("allows provider to deposit and withdraw liquidity", () => {
    const { provider } = getAccounts();

    const deposit = simnet.callPublicFn(
      CONTRACT,
      "deposit-liquidity",
      [Cl.uint(1_000_000)],
      provider
    );

    expect(deposit.result).toBeOk(Cl.uint(1_000_000));

    const afterDeposit = simnet.callReadOnlyFn(
      CONTRACT,
      "get-provider-liquidity",
      [Cl.principal(provider)],
      provider
    );

    const liq = cvToValue(afterDeposit.result) as any;
    expect(liq.total.value).toBe("1000000");
    expect(liq.locked.value).toBe("0");
    expect(liq.earnings.value).toBe("0");

    const withdraw = simnet.callPublicFn(
      CONTRACT,
      "withdraw-liquidity",
      [Cl.uint(200_000)],
      provider
    );

    expect(withdraw.result).toBeOk(Cl.uint(800_000));
  });
});

describe("Niche Cleaning Service - booking lifecycle", () => {
  it("happy path: create, accept, complete job", () => {
    const { provider, customer } = getAccounts();

    // Provider deposits liquidity first
    simnet.callPublicFn(
      CONTRACT,
      "deposit-liquidity",
      [Cl.uint(10_000_000)],
      provider
    );

    // Customer creates a bereavement cleaning job with escrowed price
    const create = simnet.callPublicFn(
      CONTRACT,
      "create-job",
      [Cl.uint(2), Cl.uint(1_000_000)],
      customer
    );

    expect(create.result).toBeOk(Cl.bool(true));

    const lastId = simnet.callReadOnlyFn(
      CONTRACT,
      "get-last-job-id",
      [],
      customer
    );

    const jobId = Number(cvToValue(lastId.result) as bigint);

    // Provider accepts the job
    const accept = simnet.callPublicFn(
      CONTRACT,
      "accept-job",
      [Cl.uint(jobId)],
      provider
    );

    expect(accept.result).toBeOk(Cl.uint(jobId));

    // Customer completes the job, paying provider
    const complete = simnet.callPublicFn(
      CONTRACT,
      "complete-job",
      [Cl.uint(jobId)],
      customer
    );

    expect(complete.result).toBeOk(Cl.uint(jobId));
  });

  it("prevents accepting a job without enough free liquidity", () => {
    const { provider, customer } = getAccounts();

    // Very small liquidity
    simnet.callPublicFn(
      CONTRACT,
      "deposit-liquidity",
      [Cl.uint(1000)],
      provider
    );

    const create = simnet.callPublicFn(
      CONTRACT,
      "create-job",
      [Cl.uint(1), Cl.uint(10_000)],
      customer
    );

    expect(create.result).toBeOk(Cl.bool(true));

    const lastId = simnet.callReadOnlyFn(
      CONTRACT,
      "get-last-job-id",
      [],
      customer
    );

    const jobId = Number(cvToValue(lastId.result) as bigint);

    const accept = simnet.callPublicFn(
      CONTRACT,
      "accept-job",
      [Cl.uint(jobId)],
      provider
    );

    expect(accept.result).toBeErr(Cl.uint(104));
  });

  it("prevents non-customer from cancelling someone else's job", () => {
    const { provider, customer } = getAccounts();

    const create = simnet.callPublicFn(
      CONTRACT,
      "create-job",
      [Cl.uint(3), Cl.uint(500_000)],
      customer
    );

    expect(create.result).toBeOk(Cl.bool(true));

    const lastId = simnet.callReadOnlyFn(
      CONTRACT,
      "get-last-job-id",
      [],
      customer
    );

    const jobId = Number(cvToValue(lastId.result) as bigint);

    const cancel = simnet.callPublicFn(
      CONTRACT,
      "cancel-job",
      [Cl.uint(jobId)],
      provider
    );

    expect(cancel.result).toBeErr(Cl.uint(101));
  });
});
