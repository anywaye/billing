module TestSupport
  module CoreLocation
    extend self

    def checkout(explicit = nil)
      explicit = ENV["CORE_PATH"].presence || ENV["CORE_SPECS_PATH"].presence if explicit.nil?

      candidates(explicit).lazy.map { |path| expand(path) }.find { |path| readable?(path) }
    end

    def path_for
      checkout || searched.first
    end

    def searched
      candidates(nil).map { |path| expand(path) }
    end

    private

      def candidates(explicit)
        return [ explicit ] if explicit.present?

        [ Rails.root.join("..", "core"), core_beside_primary_worktree ]
      end

      def core_beside_primary_worktree
        primary_worktree&.join("..", "core")
      end

      def primary_worktree
        line = `git worktree list --porcelain 2>/dev/null`.lines.first.to_s

        path = line[/\Aworktree\s+(.+)\s*\z/, 1].to_s.strip

        path.empty? ? nil : Pathname.new(path)
      rescue StandardError
        nil
      end

      def expand(path)
        return nil if path.blank?

        Pathname.new(path.to_s).expand_path
      end

      def readable?(path)
        return false if path.blank?

        path.directory? && path.join("schemas").directory? && path.join("anywaye.yml").file?
      end
  end
end
