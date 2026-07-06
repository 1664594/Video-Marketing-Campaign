CREATE TABLE creators (creator_id INT PRIMARY KEY,name VARCHAR(100) NOT NULL,email VARCHAR(150) NOT NULL UNIQUE,channel_category VARCHAR(50), 
                         -- e.g. 'Education', 'Gaming', 'Finance'
                         country VARCHAR(50) DEFAULT 'India',city VARCHAR(50),signup_date DATE NOT NULL,plan_type VARCHAR(20) NOT NULL,
                         -- 'Free','Starter','Pro','Agency'
                         monthly_revenue DECIMAL(10,2) DEFAULT 0, 
                         -- MRR from this creator (USD)
is_active BOOLEAN DEFAULT TRUE);
                         CREATE TABLE videos (video_id INT PRIMARY KEY,creator_id INT NOT NULL REFERENCES creators(creator_id),title VARCHAR(200),category VARCHAR(50),upload_date DATE NOT NULL,duration_seconds INT,baseline_views INT DEFAULT 0 
                                              -- organic views before any campaign
);
                                              CREATE TABLE campaigns (campaign_id INT PRIMARY KEY,creator_id INT NOT NULL REFERENCES creators(creator_id),video_id INT NOT NULL REFERENCES videos(video_id),start_date DATE NOT NULL,end_date DATE,budget_usd DECIMAL(10,2) NOT NULL,campaign_type VARCHAR(30), 
                                                                      -- 'View','Subscriber','Engagement'
                                                                      target_country VARCHAR(50),target_age_group VARCHAR(20), 
                                                                      -- '18-24','25-34','35-44','45+'
                                                                      status VARCHAR(20) DEFAULT 'Active' 
                                                                      -- 'Active','Completed','Paused'
);
CREATE TABLE campaign_daily_metrics (metric_id INT PRIMARY KEY,campaign_id INT NOT NULL REFERENCES campaigns(campaign_id),metric_date DATE NOT NULL,impressions INT DEFAULT 0,views INT DEFAULT 0,clicks INT DEFAULT 0,new_subscribers INT DEFAULT 0,likes INT DEFAULT 0,spend_usd DECIMAL(10,2) DEFAULT 0,watch_time_mins DECIMAL(10,2) DEFAULT 0);
                                                                      CREATE TABLE competitor_benchmarks (bench_id INT PRIMARY KEY,competitor_name VARCHAR(100),category VARCHAR(50),avg_cpm_usd DECIMAL(8,2), 
                                                                                                          -- cost per 1000 impressions
avg_ctr_pct DECIMAL(5,2), 
                                                                                                          -- click-through rate %
                                                                                                          avg_cvr_pct DECIMAL(5,2), 
                                                                                                          -- view-to-subscriber conversion %
                                                                                                          avg_roas DECIMAL(6,2),
                                                                                                          -- return on ad spend
market_share_pct DECIMAL(5,2),benchmark_month DATE);
                                                                      CREATE TABLE creator_events (event_id INT PRIMARY KEY,creator_id INT NOT NULL REFERENCES creators(creator_id),event_type VARCHAR(50),
                                                                                                   -- 'signup','first_campaign','upgrade','churn','reactivation'
event_date DATE NOT NULL,notes VARCHAR(200));
