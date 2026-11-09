-- 01_features.sql  (DuckDB)
-- Builds one row per transaction with features a bank would know AT THE MOMENT OF PAYMENT.
-- Every customer-history feature looks only at the customer's EARLIER transactions (no leakage).
--
-- Notes on the data:
--   * There is no card/customer id. Each cardholder has a unique date of birth (187 customers),
--     and dob + job + city together identify a customer.
--   * lat/long never change for a customer: they are the cardholder's HOME, not the purchase
--     location (the data dictionary says otherwise). merch_lat/merch_long = merchant location.
--
-- Run from the project root:  duckdb fraud.duckdb < sql/01_features.sql
--                     or in Python: duckdb.connect('fraud.duckdb').execute(open(...).read())

CREATE OR REPLACE TABLE transactions AS
SELECT
    DENSE_RANK() OVER (ORDER BY dob, job, city)        AS customer_id,
    CAST(trans_date_trans_time AS TIMESTAMP)           AS ts,
    *
FROM read_csv_auto('data/credit_card_fraud.csv.gz');

CREATE OR REPLACE TABLE features AS
WITH base AS (
    SELECT
        trans_num, customer_id, ts, merchant, category, state, amt, is_fraud,
        HOUR(ts)                                                     AS hour,
        ISODOW(ts)                                                   AS day_of_week,     -- 1 = Monday
        DATE_DIFF('day', CAST(dob AS DATE), CAST(ts AS DATE)) / 365.25 AS age,
        city_pop,
        -- great-circle distance between home and merchant (km)
        2 * 6371 * ASIN(SQRT(
            POWER(SIN(RADIANS(merch_lat - lat) / 2), 2) +
            COS(RADIANS(lat)) * COS(RADIANS(merch_lat)) * POWER(SIN(RADIANS(merch_long - long) / 2), 2)
        ))                                                           AS distance_km
    FROM transactions
)
SELECT
    b.*,
    (b.hour >= 22 OR b.hour < 4)                                     AS is_night,
    (b.day_of_week >= 6)                                             AS is_weekend,

    -- how busy was the card just before this payment? (current row excluded with "- 1")
    COUNT(*) OVER w1h - 1                                            AS txn_count_1h,
    COUNT(*) OVER w24h - 1                                           AS txn_count_24h,
    SUM(b.amt) OVER w24h - b.amt                                     AS amt_sum_24h,

    -- how does this amount compare with the customer's usual spending (previous 30 days)?
    (SUM(b.amt) OVER w30d - b.amt) / NULLIF(COUNT(*) OVER w30d - 1, 0) AS cust_avg_amt_30d,

    -- seconds since the customer's previous transaction
    DATE_DIFF('second', LAG(b.ts) OVER wc, b.ts)                     AS secs_since_prev,

    -- first time this customer pays at this merchant?
    ROW_NUMBER() OVER (PARTITION BY b.customer_id, b.merchant ORDER BY b.ts, b.trans_num) = 1 AS is_new_merchant,

    -- how many transactions the customer had before (history length)
    ROW_NUMBER() OVER wc - 1                                         AS prior_txn_count
FROM base b
WINDOW
    wc   AS (PARTITION BY b.customer_id ORDER BY b.ts, b.trans_num),
    w1h  AS (PARTITION BY b.customer_id ORDER BY b.ts RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW),
    w24h AS (PARTITION BY b.customer_id ORDER BY b.ts RANGE BETWEEN INTERVAL 24 HOURS PRECEDING AND CURRENT ROW),
    w30d AS (PARTITION BY b.customer_id ORDER BY b.ts RANGE BETWEEN INTERVAL 30 DAYS PRECEDING AND CURRENT ROW);

-- amount relative to the customer's usual spending (1 = typical, 10 = ten times the usual)
ALTER TABLE features ADD COLUMN amt_vs_cust_avg DOUBLE;
UPDATE features SET amt_vs_cust_avg = amt / cust_avg_amt_30d WHERE cust_avg_amt_30d > 0;

SELECT COUNT(*) AS transactions, COUNT(DISTINCT customer_id) AS customers,
       SUM(is_fraud) AS frauds, ROUND(100 * AVG(is_fraud), 2) AS fraud_pct
FROM features;
