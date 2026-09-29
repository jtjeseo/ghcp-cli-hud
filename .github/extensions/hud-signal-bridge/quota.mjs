const MAX_QUOTA_ENTRIES = 16;
const MAX_CONSECUTIVE_FAILURES = 3;
const MAX_QUOTA_BYTES = 4096;
const QUOTA_ID_PATTERN = /^[A-Za-z0-9_.-]{1,64}$/;

function isPlainObject(value) {
    if (value === null || typeof value !== "object" ||
        Array.isArray(value)) {
        return false;
    }
    const prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
}

function normalizeResetDate(value) {
    if (typeof value !== "string" || value.length > 64) {
        return null;
    }
    try {
        return Number.isFinite(Date.parse(value)) ? value : null;
    } catch {
        return null;
    }
}

export function normalizeQuotaSnapshots(quotaSnapshots, updatedAt) {
    try {
        if (!isPlainObject(quotaSnapshots)) {
            return null;
        }
    } catch {
        return null;
    }
    if (!Number.isSafeInteger(updatedAt) || updatedAt < 0) {
        return null;
    }

    const quotas = [];
    try {
        for (const id in quotaSnapshots) {
            if (!Object.prototype.hasOwnProperty.call(quotaSnapshots, id)) {
                continue;
            }
            if (quotas.length >= MAX_QUOTA_ENTRIES) {
                break;
            }

            try {
                const idMatch = QUOTA_ID_PATTERN.exec(id);
                if (idMatch === null || idMatch[0] !== id) {
                    continue;
                }
                const snapshot = quotaSnapshots[id];
                if (!isPlainObject(snapshot)) {
                    continue;
                }

                const entitlement = snapshot.entitlementRequests;
                const used = snapshot.usedRequests;
                const overage = snapshot.overage;
                if (!Number.isFinite(entitlement) ||
                    !Number.isFinite(used) ||
                    !Number.isFinite(overage)) {
                    continue;
                }

                quotas.push({
                    id,
                    unlimited: snapshot.isUnlimitedEntitlement === true ||
                        entitlement < 0,
                    used,
                    entitlement,
                    resetDate: normalizeResetDate(snapshot.resetDate),
                    overage,
                });
            } catch {
                continue;
            }
        }
    } catch {
        return null;
    }

    if (quotas.length === 0) {
        return null;
    }

    const normalized = { updatedAt, quotas };
    while (quotas.length > 0 &&
        Buffer.byteLength(JSON.stringify(normalized), "utf8") >
            MAX_QUOTA_BYTES) {
        quotas.pop();
    }
    return quotas.length > 0 ? normalized : null;
}

export function createQuotaWriter(store, onFailure = () => {}) {
    let enabled = true;
    let writeActive = false;
    let pendingSnapshot = null;
    let failureReported = false;
    let consecutiveFailures = 0;

    function disable() {
        enabled = false;
        pendingSnapshot = null;
        if (!failureReported) {
            failureReported = true;
            try {
                onFailure();
            } catch {
                // Quota reporting must not escape into the session listener.
            }
        }
    }

    function drain() {
        if (!enabled || writeActive || pendingSnapshot === null) {
            return;
        }
        writeActive = true;
        void (async () => {
            try {
                while (enabled && pendingSnapshot !== null) {
                    const snapshot = pendingSnapshot;
                    pendingSnapshot = null;
                    await store.write(snapshot);
                    consecutiveFailures = 0;
                }
            } catch {
                consecutiveFailures += 1;
                if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
                    disable();
                }
            } finally {
                writeActive = false;
                if (enabled && pendingSnapshot !== null) {
                    try {
                        drain();
                    } catch {
                        disable();
                    }
                }
            }
        })();
    }

    return function scheduleQuotaWrite(event) {
        if (!enabled) {
            return;
        }
        try {
            if (event?.type !== "assistant.usage") {
                return;
            }
            const snapshot = normalizeQuotaSnapshots(
                event.data?.quotaSnapshots,
                Date.now()
            );
            if (snapshot === null) {
                return;
            }
            pendingSnapshot = snapshot;
            drain();
        } catch {
            disable();
        }
    };
}
