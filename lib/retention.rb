# frozen_string_literal: true

require 'date'

module DokSnap
  class Retention
    def initialize(s3_uploader, app, retention_config)
      @s3_uploader = s3_uploader
      @app = app
      @retention_config = retention_config
    end

    def enforce
      backups = @s3_uploader.list_backups(@app.name)
      return if backups.empty?

      deleted = []

      # Apply count-based retention (keep_last)
      if @retention_config.keep_last
        deleted.concat(apply_count_retention(backups, @retention_config.keep_last))
      end

      # Apply time-based retention
      remaining_backups = backups.reject { |b| deleted.include?(b[:key]) }
      
      if @retention_config.daily
        deleted.concat(apply_daily_retention(remaining_backups, @retention_config.daily))
      end

      remaining_backups = backups.reject { |b| deleted.include?(b[:key]) }
      
      if @retention_config.weekly
        deleted.concat(apply_weekly_retention(remaining_backups, @retention_config.weekly))
      end

      remaining_backups = backups.reject { |b| deleted.include?(b[:key]) }
      
      if @retention_config.monthly
        deleted.concat(apply_monthly_retention(remaining_backups, @retention_config.monthly))
      end

      # Delete backups that don't meet retention criteria
      deleted.each do |key|
        @s3_uploader.delete_backup(key)
      end

      { deleted_count: deleted.length, deleted_keys: deleted }
    end

    private

    def apply_count_retention(backups, keep_count)
      return [] if backups.length <= keep_count
      
      # Keep the most recent N backups, delete the rest
      backups_to_delete = backups[keep_count..-1] || []
      backups_to_delete.map { |b| b[:key] }
    end

    def apply_daily_retention(backups, days)
      cutoff_date = Date.today - days
      backups_to_delete = []

      # Group backups by date
      backups_by_date = backups.group_by { |b| b[:last_modified].to_date }
      
      backups_by_date.each do |date, date_backups|
        if date < cutoff_date
          # Keep only the latest backup per day for dates before cutoff
          date_backups.sort_by { |b| b[:last_modified] }[0..-2].each do |backup|
            backups_to_delete << backup[:key]
          end
        else
          # For recent dates, keep all backups
        end
      end

      backups_to_delete
    end

    def apply_weekly_retention(backups, weeks)
      cutoff_date = Date.today - (weeks * 7)
      backups_to_delete = []

      # Group backups by week
      backups_by_week = backups.group_by { |b| week_of_year(b[:last_modified]) }
      
      backups_by_week.each do |week_key, week_backups|
        week_date = week_backups.first[:last_modified].to_date
        if week_date < cutoff_date
          # Keep only the latest backup per week for weeks before cutoff
          week_backups.sort_by { |b| b[:last_modified] }[0..-2].each do |backup|
            backups_to_delete << backup[:key]
          end
        end
      end

      backups_to_delete
    end

    def apply_monthly_retention(backups, months)
      cutoff_date = Date.today - (months * 30)
      backups_to_delete = []

      # Group backups by month
      backups_by_month = backups.group_by { |b| month_key(b[:last_modified]) }
      
      backups_by_month.each do |month_key, month_backups|
        month_date = month_backups.first[:last_modified].to_date
        if month_date < cutoff_date
          # Keep only the latest backup per month for months before cutoff
          month_backups.sort_by { |b| b[:last_modified] }[0..-2].each do |backup|
            backups_to_delete << backup[:key]
          end
        end
      end

      backups_to_delete
    end

    def week_of_year(time)
      date = time.to_date
      year = date.year
      week = date.strftime('%U').to_i
      "#{year}-W#{week.to_s.rjust(2, '0')}"
    end

    def month_key(time)
      date = time.to_date
      "#{date.year}-#{date.month.to_s.rjust(2, '0')}"
    end
  end
end

