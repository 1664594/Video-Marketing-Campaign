-- ────────────────────────────────────────────────────────────
-- Q1. CREATOR ACQUISITION FUNNEL
-- How many creators reach each stage?
-- Signup → First Campaign → Repeat Campaign → Upgraded Plan
-- ────────────────────────────────────────────────────────────

WITH signups AS (
    SELECT COUNT(DISTINCT creator_id) AS total_signups
    FROM creators
),

ran_campaign AS (
    SELECT COUNT(DISTINCT creator_id) AS ran_one_campaign
    FROM campaigns
),

repeat_campaigners AS (
    SELECT COUNT(DISTINCT creator_id) AS ran_multiple_campaigns
    FROM (
        SELECT creator_id
        FROM campaigns
        GROUP BY creator_id
        HAVING COUNT(campaign_id) >= 2
    ) sub
),

upgraded AS (
    SELECT COUNT(DISTINCT creator_id) AS upgraded_plan
    FROM creators
    WHERE plan_type IN ('Pro', 'Agency')
)

SELECT
    s.total_signups,
    rc.ran_one_campaign,
    ROUND(rc.ran_one_campaign * 100.0 / s.total_signups, 1) AS pct_activated,
    rep.ran_multiple_campaigns,
    ROUND(rep.ran_multiple_campaigns * 100.0 / s.total_signups, 1) AS pct_repeat,
    up.upgraded_plan,
    ROUND(up.upgraded_plan * 100.0 / s.total_signups, 1) AS pct_upgraded
FROM signups s,
     ran_campaign rc,
     repeat_campaigners rep,
     upgraded up;

-- ────────────────────────────────────────────────────────────
-- Q2. CAMPAIGN ROI BY CONTENT CATEGORY
-- Total spend vs views generated → Cost-per-view (CPV)
-- and inferred revenue (CPV benchmark × views delivered)
-- ────────────────────────────────────────────────────────────

SELECT
    v.category,
    COUNT(DISTINCT c.campaign_id) AS total_campaigns,
    ROUND(SUM(cdm.spend_usd), 2) AS total_spend_usd,
    SUM(cdm.views) AS total_views,
    SUM(cdm.new_subscribers) AS total_subscribers,
    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.views), 0) * 1000,
        2
    ) AS cost_per_1000_views,
    ROUND(SUM(cdm.watch_time_mins) / 60, 0) AS total_watch_hours,
    ROUND(
        AVG(
            CAST(cdm.views AS FLOAT) /
            NULLIF(cdm.impressions, 0) * 100
        ),
        2
    ) AS avg_vtr_pct -- View-Through Rate

FROM campaigns c
JOIN videos v
    ON c.video_id = v.video_id
JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY v.category
ORDER BY total_views DESC;

-- ────────────────────────────────────────────────────────────
-- Q3. MONTHLY COHORT RETENTION (Creator level)
-- For each signup month, what % are still active
-- 1, 2, 3 and 6 months later
-- ────────────────────────────────────────────────────────────

WITH cohort_base AS (
    SELECT
        creator_id,
        DATE_FORMAT(signup_date, '%Y-%m') AS cohort_month,
        signup_date
    FROM creators
),

campaign_activity AS (
    SELECT
        ca.creator_id,
        cb.cohort_month,
        TIMESTAMPDIFF(
            MONTH,
            cb.signup_date,
            MIN(ca.start_date)
        ) AS months_to_first_campaign
    FROM campaigns ca
    JOIN cohort_base cb
        ON ca.creator_id = cb.creator_id
    GROUP BY
        ca.creator_id,
        cb.cohort_month,
        cb.signup_date
)

SELECT
    cohort_month,
    COUNT(DISTINCT cb.creator_id) AS cohort_size,

    COUNT(
        DISTINCT CASE
            WHEN months_to_first_campaign <= 1
            THEN ca.creator_id
        END
    ) AS retained_m1,

    COUNT(
        DISTINCT CASE
            WHEN months_to_first_campaign <= 2
            THEN ca.creator_id
        END
    ) AS retained_m2,

    COUNT(
        DISTINCT CASE
            WHEN months_to_first_campaign <= 3
            THEN ca.creator_id
        END
    ) AS retained_m3,

    COUNT(
        DISTINCT CASE
            WHEN months_to_first_campaign <= 6
            THEN ca.creator_id
        END
    ) AS retained_m6,

    ROUND(
        COUNT(
            DISTINCT CASE
                WHEN months_to_first_campaign <= 1
                THEN ca.creator_id
            END
        ) * 100.0 /
        COUNT(DISTINCT cb.creator_id),
        1
    ) AS pct_m1,

    ROUND(
        COUNT(
            DISTINCT CASE
                WHEN months_to_first_campaign <= 3
                THEN ca.creator_id
            END
        ) * 100.0 /
        COUNT(DISTINCT cb.creator_id),
        1
    ) AS pct_m3

FROM cohort_base cb

LEFT JOIN campaign_activity ca
    ON cb.creator_id = ca.creator_id

GROUP BY cohort_month

ORDER BY cohort_month;

-- ────────────────────────────────────────────────────────────
-- Q4. TOP 10 CAMPAIGNS BY RETURN ON AD SPEND (ROAS)
-- Proxy:
-- (views × $0.0005 value-per-view) / spend
-- ────────────────────────────────────────────────────────────

SELECT
    c.campaign_id,
    cr.name AS creator_name,
    v.category,
    c.campaign_type,

    ROUND(SUM(cdm.spend_usd), 2) AS total_spend_usd,

    SUM(cdm.views) AS total_views,

    SUM(cdm.new_subscribers) AS subscribers_gained,

    ROUND(SUM(cdm.views) * 0.0005, 2) AS estimated_value_usd,

    ROUND(
        (SUM(cdm.views) * 0.0005) /
        NULLIF(SUM(cdm.spend_usd), 0),
        2
    ) AS roas,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.new_subscribers), 0),
        2
    ) AS cost_per_subscriber_usd

FROM campaigns c

JOIN creators cr
    ON c.creator_id = cr.creator_id

JOIN videos v
    ON c.video_id = v.video_id

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY
    c.campaign_id,
    cr.name,
    v.category,
    c.campaign_type

ORDER BY roas DESC

LIMIT 10;

-- ────────────────────────────────────────────────────────────
-- Q5. CUSTOMER LIFETIME VALUE (LTV) BY PLAN TIER
-- LTV = Avg Monthly Revenue × Avg Retention Months
-- ────────────────────────────────────────────────────────────

WITH creator_tenure AS (
    SELECT
        creator_id,
        plan_type,
        monthly_revenue,
        CASE
            WHEN is_active = TRUE THEN
                TIMESTAMPDIFF(MONTH, signup_date, CURDATE())
            ELSE (
                SELECT
                    TIMESTAMPDIFF(MONTH, cr2.signup_date, ce.event_date)
                FROM creator_events ce
                JOIN creators cr2
                    ON ce.creator_id = cr2.creator_id
                WHERE ce.creator_id = creators.creator_id
                  AND ce.event_type = 'churn'
                LIMIT 1
            )
        END AS tenure_months
    FROM creators
)

SELECT
    plan_type,
    COUNT() AS creator_count,
    ROUND(AVG(monthly_revenue), 2) AS avg_monthly_revenue_usd,
    ROUND(AVG(tenure_months), 1) AS avg_tenure_months,
    ROUND(AVG(monthly_revenue) * AVG(tenure_months), 2) AS estimated_ltv_usd,
    ROUND(AVG(monthly_revenue) * 12, 2) AS annualised_arpu_usd
FROM creator_tenure
GROUP BY plan_type
ORDER BY estimated_ltv_usd DESC;

-- ────────────────────────────────────────────────────────────
-- Q6. CHURN RISK SIGNALS
-- Creators who:
-- (a) have not run a campaign in 60+ days
-- (b) showed declining views in their last campaign
-- ────────────────────────────────────────────────────────────

WITH last_campaign AS (
    SELECT
        creator_id,
        MAX(start_date) AS last_campaign_start,
        MAX(campaign_id) AS last_campaign_id
    FROM campaigns
    GROUP BY creator_id
),

last_campaign_trend AS (
    SELECT
        lc.creator_id,
        lc.last_campaign_start,
        DATEDIFF(CURDATE(), lc.last_campaign_start) AS days_since_last_campaign,

        SUM(
            CASE
                WHEN cdm.metric_date <= lc.last_campaign_start + INTERVAL 7 DAY
                THEN cdm.views
                ELSE 0
            END
        ) AS first_week_views,

        SUM(
            CASE
                WHEN cdm.metric_date > lc.last_campaign_start + INTERVAL 7 DAY
                THEN cdm.views
                ELSE 0
            END
        ) AS latter_views

    FROM last_campaign lc
    JOIN campaign_daily_metrics cdm
        ON lc.last_campaign_id = cdm.campaign_id

    GROUP BY
        lc.creator_id,
        lc.last_campaign_start
)

SELECT
    cr.creator_id,
    cr.name,
    cr.plan_type,
    cr.monthly_revenue AS mrr_usd,
    lct.days_since_last_campaign,
    lct.first_week_views,
    lct.latter_views,

    CASE
        WHEN lct.latter_views < lct.first_week_views * 0.7
        THEN 'Declining'
        ELSE 'Stable'
    END AS view_trend,

    CASE
        WHEN lct.days_since_last_campaign > 60
             AND lct.latter_views < lct.first_week_views * 0.7
        THEN 'HIGH RISK'

        WHEN lct.days_since_last_campaign > 60
        THEN 'MEDIUM RISK'

        ELSE 'LOW RISK'
    END AS churn_risk

FROM creator_events_free AS cr

-- alias trick; real query uses creators table
-- ^ This is a conceptual placeholder; below is the actual join

JOIN last_campaign_trend lct
    ON cr.creator_id = lct.creator_id

WHERE cr.is_active = TRUE

ORDER BY lct.days_since_last_campaign DESC;

-- ────────────────────────────────────────────────────────────
-- Q6 (Corrected Version)
-- ────────────────────────────────────────────────────────────

WITH last_campaign AS (
    SELECT
        creator_id,
        MAX(start_date) AS last_campaign_start,
        MAX(campaign_id) AS last_campaign_id
    FROM campaigns
    GROUP BY creator_id
),

last_campaign_trend AS (
    SELECT
        lc.creator_id,
        lc.last_campaign_start,
        DATEDIFF(CURDATE(), lc.last_campaign_start) AS days_since_last,

        SUM(
            CASE
                WHEN cdm.metric_date
                     BETWEEN lc.last_campaign_start
                     AND lc.last_campaign_start + INTERVAL 7 DAY
                THEN cdm.views
                ELSE 0
            END
        ) AS first_week_views,

        SUM(
            CASE
                WHEN cdm.metric_date >
                     lc.last_campaign_start + INTERVAL 7 DAY
                THEN cdm.views
                ELSE 0
            END
        ) AS later_views

    FROM last_campaign lc
    JOIN campaign_daily_metrics cdm
        ON lc.last_campaign_id = cdm.campaign_id

    GROUP BY
        lc.creator_id,
        lc.last_campaign_start
)

SELECT
    cr.creator_id,
    cr.name,
    cr.plan_type,
    cr.monthly_revenue AS mrr_usd,
    lct.days_since_last,

    CASE
        WHEN lct.later_views < lct.first_week_views * 0.7
        THEN 'Declining'
        ELSE 'Stable'
    END AS view_trend,

    CASE
        WHEN lct.days_since_last > 60
             AND lct.later_views < lct.first_week_views * 0.7
        THEN 'HIGH'

        WHEN lct.days_since_last > 60
        THEN 'MEDIUM'

        ELSE 'LOW'
    END AS churn_risk

FROM creators cr

JOIN last_campaign_trend lct
    ON cr.creator_id = lct.creator_id

WHERE cr.is_active = TRUE

ORDER BY lct.days_since_last DESC;

-- ────────────────────────────────────────────────────────────
-- Q7. MONTHLY PLATFORM GROWTH KPIs
-- ────────────────────────────────────────────────────────────

WITH monthly_signups AS (
    SELECT
        DATE_FORMAT(signup_date, '%Y-%m') AS month,
        COUNT() AS new_creators
    FROM creators
    GROUP BY month
),

monthly_campaigns AS (
    SELECT
        DATE_FORMAT(start_date, '%Y-%m') AS month,
        COUNT() AS new_campaigns,
        ROUND(SUM(budget_usd), 2) AS gmv_usd
    FROM campaigns
    GROUP BY month
)

SELECT
    ms.month,
    ms.new_creators,
    mc.new_campaigns,
    mc.gmv_usd,

    ROUND(
        mc.gmv_usd /
        NULLIF(ms.new_creators, 0),
        2
    ) AS arpu_usd,

    LAG(ms.new_creators)
        OVER (ORDER BY ms.month) AS prev_signups,

    ROUND(
        (ms.new_creators -
        LAG(ms.new_creators)
            OVER (ORDER BY ms.month))
        100.0 /
        NULLIF(
            LAG(ms.new_creators)
                OVER (ORDER BY ms.month),
            0
        ),
        1
    ) AS signup_growth_pct,

    ROUND(
        (mc.gmv_usd -
        LAG(mc.gmv_usd)
            OVER (ORDER BY ms.month))
        * 100.0 /
        NULLIF(
            LAG(mc.gmv_usd)
                OVER (ORDER BY ms.month),
            0
        ),
        1
    ) AS gmv_growth_pct

FROM monthly_signups ms

LEFT JOIN monthly_campaigns mc
    ON ms.month = mc.month

ORDER BY ms.month;

-- ────────────────────────────────────────────────────────────
-- Q8. CAMPAIGN TYPE EFFECTIVENESS
-- ────────────────────────────────────────────────────────────

SELECT
    c.campaign_type,

    COUNT(DISTINCT c.campaign_id) AS num_campaigns,

    ROUND(AVG(c.budget_usd), 2) AS avg_budget_usd,

    ROUND(SUM(cdm.spend_usd), 2) AS total_spend_usd,

    SUM(cdm.views) AS total_views,

    SUM(cdm.new_subscribers) AS total_subscribers,

    SUM(cdm.likes + cdm.clicks) AS total_engagements,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.views), 0) * 1000,
        3
    ) AS cpv_per_1000,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.new_subscribers), 0),
        2
    ) AS cost_per_subscriber,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.likes + cdm.clicks), 0),
        2
    ) AS cost_per_engagement

FROM campaigns c

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY c.campaign_type

ORDER BY cost_per_subscriber ASC;


-- ────────────────────────────────────────────────────────────
-- Q9. AGE GROUP TARGETING ANALYSIS
-- Which age bracket gives Veefly creators
-- the best engagement and subscriber conversion?
-- ────────────────────────────────────────────────────────────

SELECT
    c.target_age_group,
    COUNT(DISTINCT c.campaign_id) AS campaigns,
    SUM(cdm.impressions) AS total_impressions,
    SUM(cdm.views) AS total_views,
    SUM(cdm.new_subscribers) AS subscribers,

    ROUND(
        SUM(cdm.views) * 100.0 /
        NULLIF(SUM(cdm.impressions), 0),
        2
    ) AS vtr_pct,

    ROUND(
        SUM(cdm.new_subscribers) 100.0 /
        NULLIF(SUM(cdm.views), 0),
        2
    ) AS sub_cvr_pct,

    ROUND(
        SUM(cdm.watch_time_mins) /
        NULLIF(SUM(cdm.views), 0),
        2
    ) AS avg_watch_min_per_view

FROM campaigns c

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY c.target_age_group

ORDER BY sub_cvr_pct DESC;

-- ────────────────────────────────────────────────────────────
-- Q10. VEEFLY vs COMPETITORS — CATEGORY-LEVEL BENCHMARKING
-- Where is Veefly ahead/behind on CPM, CTR, and ROAS?
-- ────────────────────────────────────────────────────────────

SELECT
    v.category,

    v.avg_cpm_usd AS veefly_cpm,
    c.avg_cpm_usd AS competitor_cpm,
    c.competitor_name,

    ROUND(
        v.avg_cpm_usd - c.avg_cpm_usd,
        2
    ) AS cpm_diff,

    v.avg_ctr_pct AS veefly_ctr,
    c.avg_ctr_pct AS competitor_ctr,

    ROUND(
        v.avg_ctr_pct - c.avg_ctr_pct,
        2
    ) AS ctr_diff,

    v.avg_roas AS veefly_roas,
    c.avg_roas AS competitor_roas,

    ROUND(
        v.avg_roas - c.avg_roas,
        2
    ) AS roas_advantage,

    CASE
        WHEN v.avg_roas > c.avg_roas
             AND v.avg_cpm_usd < c.avg_cpm_usd
        THEN 'Strong Advantage'

        WHEN v.avg_roas > c.avg_roas
        THEN 'Partial Advantage'

        ELSE 'Disadvantage'
    END AS competitive_position

FROM competitor_benchmarks v

JOIN competitor_benchmarks c
    ON v.category = c.category
   AND c.competitor_name != 'Veefly'

WHERE v.competitor_name = 'Veefly'

ORDER BY roas_advantage DESC;

-- ────────────────────────────────────────────────────────────
-- Q11. CREATOR RANKING BY PLATFORM GMV (Top 10)
-- Identify Veefly's highest-value creators for VIP
-- account management and upsell targeting
-- ────────────────────────────────────────────────────────────

SELECT
    cr.creator_id,
    cr.name,
    cr.plan_type,

    v.category AS primary_category,

    COUNT(DISTINCT c.campaign_id) AS total_campaigns,

    ROUND(
        SUM(cdm.spend_usd),
        2
    ) AS lifetime_spend_usd,

    SUM(cdm.views) AS lifetime_views,

    SUM(cdm.new_subscribers) AS lifetime_subscribers,

    ROUND(
        SUM(cdm.spend_usd) /
        COUNT(DISTINCT c.campaign_id),
        2
    ) AS avg_campaign_value_usd,

    DENSE_RANK() OVER (
        ORDER BY SUM(cdm.spend_usd) DESC
    ) AS spend_rank

FROM creators cr

JOIN campaigns c
    ON cr.creator_id = c.creator_id

JOIN videos v
    ON c.video_id = v.video_id

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY
    cr.creator_id,
    cr.name,
    cr.plan_type,
    v.category

ORDER BY lifetime_spend_usd DESC

LIMIT 10;

-- ────────────────────────────────────────────────────────────
-- Q12. AVERAGE TIME-TO-FIRST-CAMPAIGN (TT1C) BY PLAN TYPE
-- Fast activation = high intent; slow = at-risk
-- ────────────────────────────────────────────────────────────

SELECT
    cr.plan_type,

    COUNT() AS creators_with_campaign,

    ROUND(
        AVG(
            DATEDIFF(
                MIN(c.start_date),
                cr.signup_date
            )
        ),
        0
    ) AS avg_days_to_first_campaign,

    MIN(
        DATEDIFF(
            MIN(c.start_date),
            cr.signup_date
        )
    ) AS min_days,

    MAX(
        DATEDIFF(
            MIN(c.start_date),
            cr.signup_date
        )
    ) AS max_days,

    ROUND(
        STDDEV(
            DATEDIFF(
                MIN(c.start_date),
                cr.signup_date
            )
        ),
        0
    ) AS stddev_days

FROM creators cr

JOIN campaigns c
    ON cr.creator_id = c.creator_id

GROUP BY
    cr.plan_type,
    cr.creator_id,
    cr.signup_date

-- wrap in outer query to aggregate by plan_type
-- Full nested version,

COUNT() AS creators,

ROUND(
    AVG(days_to_first),
    0
) AS avg_days_to_activation,

ROUND(
    STDDEV(days_to_first),
    0
) AS stddev_days

FROM (
    SELECT
        cr.creator_id,
        cr.plan_type,

        DATEDIFF(
            MIN(c.start_date),
            cr.signup_date
        ) AS days_to_first

    FROM creators cr

    JOIN campaigns c
        ON cr.creator_id = c.creator_id

    GROUP BY
        cr.creator_id,
        cr.plan_type,
        cr.signup_date

) AS activation

GROUP BY plan_type

ORDER BY avg_days_to_activation;


-- ────────────────────────────────────────────────────────────
-- Q13. VIDEO ORGANIC vs PROMOTED PERFORMANCE
-- What uplift (%) do campaigns drive in views
-- above the organic baseline?
-- ────────────────────────────────────────────────────────────

SELECT
    v.video_id,
    v.title,
    v.category,
    cr.name AS creator_name,
    v.baseline_views,

    SUM(cdm.views) AS promoted_views,

    ROUND(
        (SUM(cdm.views) - v.baseline_views) * 100.0 /
        NULLIF(v.baseline_views, 0),
        1
    ) AS view_uplift_pct,

    SUM(cdm.new_subscribers) AS subscribers_from_campaign,

    ROUND(
        SUM(cdm.spend_usd),
        2
    ) AS total_spend_usd,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.views) - v.baseline_views, 0) * 1000,
        2
    ) AS cost_per_incremental_1000_views

FROM videos v

JOIN creators cr
    ON v.creator_id = cr.creator_id

JOIN campaigns c
    ON v.video_id = c.video_id

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY
    v.video_id,
    v.title,
    v.category,
    cr.name,
    v.baseline_views

ORDER BY view_uplift_pct DESC;

-- ────────────────────────────────────────────────────────────
-- Q14. REVENUE CONCENTRATION (PARETO ANALYSIS)
-- What % of GMV comes from top 20% of creators?
-- ────────────────────────────────────────────────────────────

WITH creator_spend AS (

    SELECT
        cr.creator_id,
        cr.name,
        cr.plan_type,

        ROUND(
            SUM(cdm.spend_usd),
            2
        ) AS total_spend

    FROM creators cr

    JOIN campaigns c
        ON cr.creator_id = c.creator_id

    JOIN campaign_daily_metrics cdm
        ON c.campaign_id = cdm.campaign_id

    GROUP BY
        cr.creator_id,
        cr.name,
        cr.plan_type
),

ranked AS (

    SELECT
        ,

        NTILE(5) OVER (
            ORDER BY total_spend DESC
        ) AS spend_quintile,

        SUM(total_spend) OVER () AS platform_total_spend

    FROM creator_spend
)

SELECT
    spend_quintile,

    COUNT() AS creator_count,

    ROUND(
        SUM(total_spend),
        2
    ) AS quintile_spend,

    ROUND(
        SUM(total_spend) * 100.0 /
        MAX(platform_total_spend),
        1
    ) AS pct_of_total_gmv,

    ROUND(
        SUM(SUM(total_spend)) OVER (
            ORDER BY spend_quintile
        ) 100.0 /
        MAX(platform_total_spend),
        1
    ) AS cumulative_pct

FROM ranked

GROUP BY spend_quintile

ORDER BY spend_quintile;

-- ────────────────────────────────────────────────────────────
-- Q15. CAMPAIGN BUDGET SWEET SPOT
-- Do creators who spend $200–500 per campaign get
-- better CPV than those who spend $500+?
-- ────────────────────────────────────────────────────────────

SELECT

    CASE
        WHEN c.budget_usd < 100 THEN 'Under $100'
        WHEN c.budget_usd < 200 THEN '$100–200'
        WHEN c.budget_usd < 500 THEN '$200–500'
        WHEN c.budget_usd < 1000 THEN '$500–1000'
        WHEN c.budget_usd < 2000 THEN '$1000–2000'
        ELSE 'Above $2000'
    END AS budget_bucket,

    COUNT(DISTINCT c.campaign_id) AS campaigns,

    ROUND(
        AVG(c.budget_usd),
        2
    ) AS avg_budget_usd,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.views), 0) * 1000,
        3
    ) AS cost_per_1000_views,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.new_subscribers), 0),
        2
    ) AS cost_per_subscriber,

    ROUND(
        AVG(
            cdm.views * 100.0 /
            NULLIF(cdm.impressions, 0)
        ),
        2
    ) AS avg_vtr_pct

FROM campaigns c

JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id

GROUP BY budget_bucket

ORDER BY cost_per_1000_views ASC;

-- ────────────────────────────────────────────────────────────
-- Q16. EXECUTIVE PLATFORM HEALTH SCORECARD
-- Single-query summary for leadership reporting
-- ────────────────────────────────────────────────────────────

SELECT

    COUNT(DISTINCT cr.creator_id) AS total_creators,

    SUM(
        CASE
            WHEN cr.is_active THEN 1
            ELSE 0
        END
    ) AS active_creators,

    ROUND(
        SUM(
            CASE
                WHEN cr.is_active THEN 1
                ELSE 0
            END
        ) * 100.0 /
        COUNT(DISTINCT cr.creator_id),
        1
    ) AS active_rate_pct,

    COUNT(DISTINCT c.campaign_id) AS total_campaigns,

    ROUND(
        SUM(c.budget_usd),
        2
    ) AS total_platform_gmv_usd,

    ROUND(
        SUM(cdm.views) / 1000000.0,
        2
    ) AS total_views_millions,

    SUM(cdm.new_subscribers) AS total_subscribers_delivered,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.views), 0) * 1000,
        3
    ) AS blended_cpv,

    ROUND(
        SUM(cdm.spend_usd) /
        NULLIF(SUM(cdm.new_subscribers), 0),
        2
    ) AS blended_cost_per_subscriber,

    ROUND(
        AVG(cr.monthly_revenue),
        2
    ) AS avg_mrr_per_creator_usd,

    ROUND(
        SUM(cr.monthly_revenue) * 12,
        2
    ) AS annualised_platform_revenue_usd

FROM creators cr

LEFT JOIN campaigns c
    ON cr.creator_id = c.creator_id

LEFT JOIN campaign_daily_metrics cdm
    ON c.campaign_id = cdm.campaign_id;

