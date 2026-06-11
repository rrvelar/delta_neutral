class BoundedJsonlTail
  DEFAULT_BYTES = 256.kilobytes

  def self.read(path, lines:, max_bytes: DEFAULT_BYTES)
    new(path: path, lines: lines, max_bytes: max_bytes).read
  end

  def initialize(path:, lines:, max_bytes: DEFAULT_BYTES)
    @path = Pathname(path)
    @lines = lines.to_i
    @max_bytes = max_bytes.to_i
  end

  def read
    return [] unless lines.positive? && File.file?(path)

    content = tail_content
    content.lines.last(lines).filter_map do |line|
      next if line.blank?

      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  rescue SystemCallError
    []
  end

  private

  attr_reader :path, :lines, :max_bytes

  def tail_content
    File.open(path, "rb") do |file|
      size = file.size
      offset = [ size - max_bytes, 0 ].max
      file.seek(offset)
      file.gets if offset.positive?
      file.read.to_s
    end
  end
end
