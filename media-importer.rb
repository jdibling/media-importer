#!/usr/bin/env ruby

require 'shellwords'
require 'syslog'

class String
  def snake
    self.downcase.gsub(/[^a-z0-9 ]/, '').gsub(/ /, '_').gsub(/_+/, '_').gsub(/^(.*)_$/, '\1')
  end
end

def get_tags path
  case File.extname(path)[1..-1].downcase.to_sym
  when :flac
    get_flac_tags path
  when :mp3
    get_mp3_tags path
  else
    nil
  end
end

def normalize_tag tag
  case tag
  when :track, :tracknumber
    :track_num
  when :album
    :album_name
  when :title, :song_title
    :track_name
  when :discnumber
    :disc_num
  when :artist
    :artist_name
  else
    "unhandled_tag_#{tag}".to_sym
  end
end

def normalize_path tags, root_path
  begin
    tags[:disc_num] = 1 unless !tags[:disc_num].nil? && tags[:disc_num].to_i > 0
    disc = "d#{sprintf("%0.2d", tags[:disc_num].to_i)}"
    track = "t#{sprintf("%0.2d", tags[:track_num].to_i)}"
    title = tags[:track_name].snake
    album = tags[:album_name].snake
    artist = tags[:artist_name].snake
    format = tags[:format]
    "#{root_path}#{artist}/#{album}/#{disc}#{track}_#{title}.#{format}"
  rescue NoMethodError => e
    nil
  end
end

def get_flac_tags path
  raw = `metaflac --export-tags-to=- #{File.expand_path(path.shellescape)}`
  raise "Error processing path for \"#{path}\"" if raw.nil? || raw.empty?
  o = raw.split("\n").inject({}) do |memo, pair|
    a = pair.split("=")
    memo.merge({ normalize_tag(a[0].snake.to_sym) => a[1..-1].join(":") })
  end 
  o.merge({:format=>:flac})
end

def get_mp3_tags path
  raw = `id3tool #{File.expand_path(path.shellescape)}`
  raise "Error processing path for \"#{path}\"" if raw.nil? || raw.empty?
  begin
      o = raw.force_encoding("iso-8859-1").split("\n").inject({}) { |memo, pair|
        a = pair.split(":")
        next memo if a.empty?
        memo.merge( { normalize_tag(a[0].strip.snake.to_sym) => a[1..-1].join(":").strip } )
      }
  rescue ArgumentError, NameError
    $stderr.puts "Error processing file #{raw} :#{$!}"
    $stderr.puts "Raw:#{raw}\n o:#{o}\n a:#{a}"
   exit
  end
  o.merge({:format=>:mp3})
end


$stderr.puts ARGV[0]
$stderr.puts ARGV[1]

src_dir = ARGV[0]
dst_dir =ARGV[1]
rej_dir = "/scratch/rejected/"

Syslog.open("media-importer", Syslog::LOG_CONS | Syslog::LOG_NDELAY | Syslog::LOG_PERROR | Syslog::LOG_PID, Syslog::LOG_DAEMON | Syslog::LOG_LOCAL1)
Syslog.log(Syslog::LOG_INFO, " importing from %s to %s", src_dir, dst_dir)
Syslog.log(Syslog::LOG_INFO, " reading source directory '%s'", src_dir)

if !File.directory? src_dir
  SSyslog.log(Syslog::LOG_ERR, " Source directory does not exist: %s", src_dir)
  $stderr.puts "Error: source directory does not exist: #{src_dir}"
  exit
end

if !File.directory? dst_dir
  SSyslog.log(Syslog::LOG_ERR, " Destination directory does not exist: %s", src_dir)
  $stderr.puts "Error: destination directory does not exist: #{dst_dir}"
  exit
end

count = 0
src_files = `find #{src_dir} -iname "*.flac" -o -iname "*.mp3"`.split("\n")
Syslog.log(Syslog::LOG_INFO, " Indexing %d files in %s", src_files.size, src_dir)

all_files = src_files.inject([]) do |memo, path|
  Syslog.log(Syslog::LOG_INFO, " %d files indexed", count) if (count += 1) % 100 == 0
  tags = get_tags path
  memo << {:SourcePath => path, :Tags => tags, :DestPath => normalize_path(tags, dst_dir) }
end

files = all_files.group_by {|index| File.extname(index[:SourcePath])[1..-1].to_sym}

files.each do |ext, ary|
  Syslog.log(Syslog::LOG_INFO, " Indexed %d %s files", ary.size, ext)
end

actionable = all_files.select do |file|
  file[:SourcePath] != file[:DestPath]
end

require 'fileutils'

$stderr.puts "Moving #{actionable.size} files..."
Syslog.log(Syslog::LOG_INFO, " Moving %d files", actionable.size)

actionable.each do |act| 
  if act[:DestPath].nil? || act[:DestPath].empty?
    act[:DestPath] = rej_dir + File.basename(act[:SourcePath])
    Syslog.log(Syslog::LOG_WARNING, "Rejecting %s to %s", act[:SourcePath], act[:DestPath])
    rej_tags = get_tags act[:SourcePath]
    Syslog.log(Syslog::LOG_WARNING, "Tags for rejected file to follow")
    rej_tags.each do |rt|
      Syslog.log(Syslog::LOG_INFO, rt.to_s)
    end

  end

  Syslog.log(Syslog::LOG_INFO, " Moving %s to %s", act[:SourcePath], act[:DestPath])

  FileUtils.mkdir_p File.dirname act[:DestPath]
  FileUtils.cp act[:SourcePath], act[:DestPath] unless File.exist?(act[:DestPath])
  FileUtils.rm act[:SourcePath]
end

Syslog.log(Syslog::LOG_INFO, " Re-indexing complete.")
$stderr.puts "Re-indexing complete."


