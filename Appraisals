# frozen_string_literal: true

# json 3.0 dropped the quirks_mode keyword from JSON.generate, which ActiveSupport's JSON
# encoder passes on every call. Rails fixed it in 8.1; every released 7.1, 7.2 and 8.0
# still calls it, so the three appraisals below hold json under 3 rather than failing on
# `ArgumentError: unknown keyword: quirks_mode` in 12 of the 16 matrix cells.

appraise "ar-71" do
  gem "json", "< 3"
  gem "activerecord", "~> 7.1.0"
end

appraise "ar-72" do
  gem "json", "< 3"
  gem "activerecord", "~> 7.2.0"
end

appraise "ar-80" do
  gem "json", "< 3"
  gem "activerecord", "~> 8.0.0"
end

appraise "ar-81" do
  gem "activerecord", "~> 8.1.0"
end
