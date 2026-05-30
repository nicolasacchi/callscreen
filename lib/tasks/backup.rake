# WAL-safe online backup of every SQLite database configured for the current
# environment (primary + Solid Queue) into storage/backups/, pruning anything
# older than 14 days. Uses SQLite's `VACUUM INTO`, which takes a consistent
# snapshot while writers are active — unlike a plain `cp` of a WAL-mode file.
#
# Run from the host on a cron, e.g. (see README / ops docs):
#   0 3 * * *  docker exec callscreen ./bin/rails db:backup >> /var/log/callscreen-backup.log 2>&1
#
# Restore: stop the container, copy a snapshot back over storage/<env>.sqlite3,
# start the container.
namespace :db do
  desc "WAL-safe SQLite backup of all configured databases to storage/backups/ (keeps 14 days)"
  task backup: :environment do
    require "sqlite3"
    require "fileutils"

    dir = Rails.root.join("storage", "backups")
    FileUtils.mkdir_p(dir)
    # BACKUP_STAMP lets the caller pin the filename (tests); default to UTC now.
    stamp = ENV.fetch("BACKUP_STAMP") { Time.now.utc.strftime("%Y%m%d-%H%M%S") }
    keep_days = Integer(ENV.fetch("BACKUP_KEEP_DAYS", "14"))

    configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
    sqlite_configs = configs.select { |c| c.adapter.to_s.include?("sqlite") }

    if sqlite_configs.empty?
      warn "db:backup: no SQLite databases configured for #{Rails.env}; nothing to do"
      next
    end

    sqlite_configs.each do |cfg|
      src = File.expand_path(cfg.database.to_s, Rails.root)
      unless File.exist?(src)
        warn "db:backup: #{cfg.name} source #{src} missing, skipping"
        next
      end
      dest = dir.join("#{Rails.env}-#{cfg.name}-#{stamp}.sqlite3")
      db = SQLite3::Database.new(src)
      begin
        db.execute("VACUUM INTO ?", [ dest.to_s ])
      ensure
        db.close
      end
      puts "db:backup: #{cfg.name} → #{dest} (#{File.size(dest)} bytes)"
    end

    # Prune old snapshots.
    cutoff = Time.now - (keep_days * 24 * 60 * 60)
    Dir.glob(dir.join("*.sqlite3")).each do |f|
      next unless File.mtime(f) < cutoff
      File.delete(f)
      puts "db:backup: pruned #{File.basename(f)}"
    end
  end
end
