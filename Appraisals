# frozen_string_literal: true

appraise "ar-80" do
  # json 3.0 dropped the quirks_mode keyword from JSON.generate, which ActiveSupport's JSON
  # encoder passes on every call. Rails fixed it in 8.1; 8.0 still calls it, so
  # that appraisal holds json under 3 rather than failing on
  # `ArgumentError: unknown keyword: quirks_mode`.
  gem "json", "< 3"
  gem "activerecord", "~> 8.0.0"
end

appraise "ar-81" do
  gem "activerecord", "~> 8.1.0"
end
