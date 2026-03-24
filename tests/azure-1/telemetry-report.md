# Migration Telemetry Report

Generated: 2026-03-24 20:17:09

**Mode:** multi-worker (1 workers)  
**Source:** `C:\code\b2c-to-meeid-migration-tool\tests\azure-1`  
**Migrate files:** 1 / 1 (37711 lines)  
**Phone files:** 1 / 1 (3330 lines)

## Migrate Workers

### Latency by Component (ms)

| Metric | n | avg | min | p50 | p90 | p95 | p99 | max |
|--------|---|-----|-----|-----|-----|-----|-----|-----|
| B2C fetch (per batch) | 1713 | 958 | 721 | 916 | 1088 | 1197 | 1801 | 2878 |
| EEID create (pure API) | 33680 | 316 | 234 | 288 | 372 | 617 | 835 | 2306 |
| EEID create (total op) | 33680 | 316 | 234 | 288 | 372 | 617 | 835 | 2306 |
| EEID max (per batch) | 1713 | 480 | 0 | 371 | 817 | 869 | 1112 | 2306 |
| EEID avg (per batch) | 1713 | 313 | 77 | 290 | 370 | 458 | 674 | 769 |
| Wall time (b2c+eeid_max) | 1713 | 1438 | 799 | 1336 | 1805 | 1952 | 2564 | 3792 |

### Share of Wall Time

| Component | Time (s) | % of Wall |
|-----------|----------|-----------|
| B2C fetch | 1,640.8 | 67% |
| EEID create | 821.7 | 33% |
| **Total wall** | **2,462.5** | 1713 batches |

### Theoretical Max (20 users/batch)

| Scenario | users/s | users/min |
|----------|---------|-----------|
| At avg wall (1438ms) | 13.9 | 834 |
| At min wall (799ms) | 25.0 | 1,502 |

### Tail Latency & Throttles

- Slow EEID creates (>1s): 70 / 33680 (0.2%)
- Graph.Throttled B2C: 0
- Graph.Throttled EEID: 0

## Phone Registration Workers

### Outcomes

| Outcome | Count |
|---------|-------|
| Succeeded (phone registered) | 1071 |
| Skipped (no phone in B2C) | 0 |
| Failed (exhausted retries) | 38 |
| **Total** | **1109** |

#### Failure Breakdown

| Category | Count |
|----------|-------|
| Step: eeid-register | 38 |
| Error: 403 | 38 |

### Latency by Phase (ms)

| Metric | n | avg | min | p50 | p90 | p95 | p99 | max |
|--------|---|-----|-----|-----|-----|-----|-----|-----|
| B2C GET phone (success) | 1071 | 423 | 113 | 375 | 734 | 791 | 980 | 1339 |
| B2C GET phone (all API) | 1110 | 428 | 113 | 378 | 740 | 795 | 993 | 1980 |
| EEID POST phone (success) | 1071 | 1858 | 826 | 1760 | 2219 | 2372 | 2876 | 24771 |
| EEID POST phone (all API) | 1109 | 1820 | 283 | 1745 | 2214 | 2365 | 2876 | 24771 |
| Total per user (success) | 1071 | 2281 | 1187 | 2194 | 2748 | 2914 | 3518 | 25007 |
| B2C GET phone (skipped) | — | — | — | — | — | — | — | — |

### Share of Phone Time

| Component | Time (s) | % of API Time |
|-----------|----------|---------------|
| B2C GET phone | 452.8 | 19% |
| EEID POST phone | 1,989.5 | 81% |

### Tail Latency & Throttles

- Slow B2C GET (>1s): 9 / 1071 (0.8%)
- Slow EEID POST (>1s): 1074 / 1109 (96.8%)
- Graph.Throttled total: 0
  - B2C: 0
  - EEID: 0

## Cross-Pipeline Summary

| Metric | Count |
|--------|-------|
| Users migrated (EEID created) | 33680 |
| Phones registered | 1071 |
| Phones skipped | 0 |
| Phones failed | 38 |
| Phone pipeline coverage | 3.3% |
| Users with phone registered | 3.2% |

