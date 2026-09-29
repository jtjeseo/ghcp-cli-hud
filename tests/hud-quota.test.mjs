import assert from "node:assert/strict";
import test from "node:test";
import {
    mkdir,
    mkdtemp,
    readFile,
    readdir,
    rm,
    utimes,
    writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
    createQuotaWriter,
    normalizeQuotaSnapshots,
} from "../.github/extensions/hud-signal-bridge/quota.mjs";
import {
    createQuotaStateStore,
    createSignalStateStore,
} from "../.github/extensions/hud-signal-bridge/state-store.mjs";

function quota(overrides = {}) {
    return {
        isUnlimitedEntitlement: false,
        entitlementRequests: 100,
        usedRequests: 25,
        resetDate: "2026-09-30T00:00:00.000Z",
        overage: 0,
        ...overrides,
    };
}

function quotaEvent(quotaSnapshots) {
    return {
        type: "assistant.usage",
        data: { quotaSnapshots },
    };
}

function signalSnapshot(sessionId, updatedAtMs) {
    return {
        version: 1,
        sessionId,
        updatedAtMs,
        phase: "idle",
        phaseAtMs: updatedAtMs,
        recentIncreaseNanoAiu: null,
        recentAtMs: null,
        activeSubagentCount: null,
    };
}

test("normalizes and atomically writes the exact account quota schema", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-quota-"));
    try {
        const updatedAt = 1_790_674_200_000;
        const expected = {
            updatedAt,
            quotas: [
                {
                    id: "chat",
                    unlimited: false,
                    used: 25,
                    entitlement: 100,
                    resetDate: "2026-09-30T00:00:00.000Z",
                    overage: 0,
                },
                {
                    id: "premium_interactions",
                    unlimited: true,
                    used: 7,
                    entitlement: -1,
                    resetDate: null,
                    overage: 2,
                },
                {
                    id: "completions",
                    unlimited: true,
                    used: 4,
                    entitlement: 20,
                    resetDate: "2026-10-01",
                    overage: 1,
                },
            ],
        };
        const normalized = normalizeQuotaSnapshots({
            chat: quota(),
            premium_interactions: quota({
                entitlementRequests: -1,
                usedRequests: 7,
                resetDate: "not a date",
                overage: 2,
            }),
            completions: quota({
                isUnlimitedEntitlement: true,
                entitlementRequests: 20,
                usedRequests: 4,
                resetDate: "2026-10-01",
                overage: 1,
            }),
        }, updatedAt);
        assert.deepEqual(normalized, expected);
        assert.deepEqual(Object.keys(normalized), ["updatedAt", "quotas"]);
        assert.deepEqual(Object.keys(normalized.quotas[0]), [
            "id",
            "unlimited",
            "used",
            "entitlement",
            "resetDate",
            "overage",
        ]);

        const store = await createQuotaStateStore(home);
        await store.write(normalized);
        const path = join(
            home,
            "state",
            "hud-signal-bridge",
            "hud-quota.json"
        );
        const contents = await readFile(path, "utf8");
        assert.equal(contents, JSON.stringify(expected));
        assert.deepEqual(JSON.parse(contents), expected);
        assert.ok(Buffer.byteLength(contents, "utf8") <= 4096);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("skips malformed quota entries and caps large maps at 16 entries", () => {
    const normalized = normalizeQuotaSnapshots({
        nan: quota({ usedRequests: Number.NaN }),
        string: quota({ entitlementRequests: "100" }),
        "bad id": quota(),
        valid: quota({ usedRequests: 3 }),
    }, 1);
    assert.deepEqual(normalized.quotas.map(({ id }) => id), ["valid"]);

    const hugeMap = Object.fromEntries(
        Array.from({ length: 100 }, (_, index) => [
            `quota-${index}`,
            quota({ usedRequests: index }),
        ])
    );
    const capped = normalizeQuotaSnapshots(hugeMap, 2);
    assert.equal(capped.quotas.length, 16);
    assert.deepEqual(
        capped.quotas.map(({ id }) => id),
        Array.from({ length: 16 }, (_, index) => `quota-${index}`)
    );
    assert.ok(Buffer.byteLength(JSON.stringify(capped), "utf8") <= 4096);

    const lateValidEntry = normalizeQuotaSnapshots({
        ...Object.fromEntries(
            Array.from({ length: 20 }, (_, index) => [
                `invalid-${index}`,
                quota({ usedRequests: "not numeric" }),
            ])
        ),
        "last-valid": quota(),
    }, 3);
    assert.deepEqual(lateValidEntry.quotas.map(({ id }) => id), ["last-valid"]);
});

test("ignores non-object quota maps and writes nothing without valid entries", async () => {
    const nonObjects = [
        null,
        undefined,
        [],
        "quota",
        1,
        Object.create({ inherited: quota() }),
    ];
    for (const value of nonObjects) {
        assert.equal(normalizeQuotaSnapshots(value, 1), null);
    }

    const home = await mkdtemp(join(tmpdir(), "copilot-hud-quota-empty-"));
    try {
        const store = await createQuotaStateStore(home);
        const scheduleQuotaWrite = createQuotaWriter(store);
        for (const value of nonObjects) {
            scheduleQuotaWrite(quotaEvent(value));
        }
        scheduleQuotaWrite(quotaEvent({
            invalid: quota({ overage: "0" }),
        }));
        await new Promise((resolve) => setImmediate(resolve));
        const directory = join(home, "state", "hud-signal-bridge");
        assert.deepEqual(await readdir(directory), []);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("coalesces pending writes so the latest quota snapshot wins", async () => {
    const writes = [];
    let releaseFirstWrite;
    let firstWriteStarted;
    let secondWriteFinished;
    const firstStarted = new Promise((resolve) => {
        firstWriteStarted = resolve;
    });
    const firstWriteGate = new Promise((resolve) => {
        releaseFirstWrite = resolve;
    });
    const secondFinished = new Promise((resolve) => {
        secondWriteFinished = resolve;
    });
    const store = {
        async write(snapshot) {
            writes.push(snapshot);
            if (writes.length === 1) {
                firstWriteStarted();
                await firstWriteGate;
            } else {
                secondWriteFinished();
            }
        },
    };
    const scheduleQuotaWrite = createQuotaWriter(store, () => {
        assert.fail("valid quota writes must not report a failure");
    });

    scheduleQuotaWrite(quotaEvent({ chat: quota({ usedRequests: 1 }) }));
    await firstStarted;
    scheduleQuotaWrite(quotaEvent({ chat: quota({ usedRequests: 2 }) }));
    scheduleQuotaWrite(quotaEvent({ chat: quota({ usedRequests: 3 }) }));
    releaseFirstWrite();
    await secondFinished;

    assert.deepEqual(writes.map((snapshot) => snapshot.quotas[0].used), [1, 3]);
});

test("quota write failure is contained and does not block signal snapshots", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-quota-failure-"));
    try {
        const quotaStore = await createQuotaStateStore(home);
        const sessionId = "quota-independent";
        const signalStore = await createSignalStateStore(home, sessionId);
        const directory = join(home, "state", "hud-signal-bridge");
        await mkdir(join(directory, "hud-quota.json"));

        let reportFailure;
        const failureReported = new Promise((resolve) => {
            reportFailure = resolve;
        });
        let failureCount = 0;
        const scheduleQuotaWrite = createQuotaWriter(quotaStore, () => {
            failureCount += 1;
            reportFailure();
        });
        const event = quotaEvent({ chat: quota() });
        let reported = false;
        failureReported.then(() => { reported = true; });
        for (let index = 0; index < 10 && !reported; index += 1) {
            assert.doesNotThrow(() => scheduleQuotaWrite(event));
            await Promise.race([
                failureReported,
                new Promise((resolve) => setTimeout(resolve, 1500)),
            ]);
        }
        await failureReported;
        assert.equal(failureCount, 1);
        assert.doesNotThrow(() => scheduleQuotaWrite(event));

        const expected = signalSnapshot(sessionId, 10);
        await signalStore.write(expected);
        const signalPath = join(
            directory,
            `hud-signal-${sessionId}.json`
        );
        assert.deepEqual(JSON.parse(await readFile(signalPath, "utf8")), expected);
        assert.deepEqual((await readdir(directory)).sort(), [
            "hud-quota.json",
            `hud-signal-${sessionId}.json`,
        ]);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("prunes stale quota temporary files without involving signal pruning", async () => {
    const home = await mkdtemp(join(tmpdir(), "copilot-hud-quota-prune-"));
    try {
        const directory = join(home, "state", "hud-signal-bridge");
        await mkdir(directory, { recursive: true });
        const staleTemporary = join(
            directory,
            "hud-quota.json.1.12345678-1234-1234-1234-123456789abc.tmp"
        );
        await writeFile(staleTemporary, "stale");
        const oldDate = new Date(Date.now() - 60 * 60 * 1000);
        await utimes(staleTemporary, oldDate, oldDate);

        await createQuotaStateStore(home);
        assert.deepEqual(await readdir(directory), []);
    } finally {
        await rm(home, { recursive: true, force: true });
    }
});

test("quota capture tolerates transient failures and disables after three in a row", async () => {
    let attempts = 0;
    let failuresRemaining = 2;
    const writes = [];
    const store = {
        async write(snapshot) {
            attempts += 1;
            if (failuresRemaining > 0) {
                failuresRemaining -= 1;
                throw new Error("transient");
            }
            writes.push(snapshot);
        },
    };
    let failureCount = 0;
    const settle = () => new Promise((resolve) => setTimeout(resolve, 10));
    const scheduleQuotaWrite = createQuotaWriter(store, () => {
        failureCount += 1;
    });
    const event = quotaEvent({ chat: quota() });
    for (let index = 0; index < 3; index += 1) {
        scheduleQuotaWrite(event);
        await settle();
    }
    assert.equal(attempts, 3);
    assert.equal(writes.length, 1, "capture must recover after two transient failures");
    assert.equal(failureCount, 0);

    failuresRemaining = 3;
    for (let index = 0; index < 5; index += 1) {
        scheduleQuotaWrite(event);
        await settle();
    }
    assert.equal(attempts, 6, "capture must stop after three consecutive failures");
    assert.equal(failureCount, 1);
});