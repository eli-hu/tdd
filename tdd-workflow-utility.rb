# frozen_string_literal: true

require 'tty-config'
require 'tty-box'
require 'tty-prompt'
require 'tty-spinner'
require 'ruby-progressbar'
require 'pastel'
require 'fileutils'
require 'pathname'
require 'facets'
require 'yaml'
require 'yaml/store'
require 'csv'
require 'mini_exiftool'
require 'logger'

require_relative 'lib/tdd'

def execute(function, config, log)
  prompt = TTY::Prompt.new
  pastel = Pastel.new

  case function

  when 'createSepFolders'
    function_path = Pathname.new(config.fetch(:createSepFolders))
    choices = TDD.get_choices function_path
    batch = prompt.select('Create Separation Folders:', choices, per_page: 15)
    if batch == 'Main Menu'
      function = TDD.main_menu
      execute function, config, log
    else
      response = prompt.select("Process Batch #{pastel.yellow(batch.basename)}?", %w[Yes No])
      if response == 'Yes'
        spinner = TDD.new_spinner('Creating Separation Folders')
        spinner.auto_spin
        batch.children.each do |volume|
          if volume.basename.to_s == 'Output'
            next
          else
            oclc = volume.basename.to_s
            meta_path = "#{batch}/Output/TIFF/#{batch.basename.to_s}/#{oclc}/metadata"
            FileUtils.mkdir_p meta_path
            FileUtils.cp("#{volume}/metadata.txt", "#{meta_path}/metadata.txt")
          end
        end
        FileUtils.mv(batch, batch.parent.parent.join("1_to_separation/#{batch.basename.to_s}"))
        log.info("#{TDD.timestamp} : created separation folders for batch #{batch.basename}")
        spinner.success(pastel.green('Separation Folders Created'))
        prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
        function = TDD.main_menu
        execute function, config, log
      else
        function = TDD.main_menu
        execute function, config, log
      end
    end


  when 'archiveDigiBatch'
    function_path = Pathname.new(config.fetch(:archiveDigiBatch))
    choices = TDD.get_choices function_path
    batch = prompt.select('Archive Digi Batch:', choices, per_page: 15)
    if batch == 'Main Menu'
      function = TDD.main_menu
      execute function, config, log
    else
      response = prompt.select("Archive Digi Batch #{pastel.yellow(batch.basename)}?", %w[Yes No])
      if response == 'Yes'
        date_digitized = Time.now.strftime('%Y%m%d')
        batchstr = batch.to_s.gsub('\\', '/')
        metadata_paths = Dir.glob("#{batchstr}/Output/TIFF/**/metadata.txt")
        batch_size = metadata_paths.size
        bar = ProgressBar.create(total: metadata_paths.size, format: 'Archiving Digi Batch: %c/%C |%W| %a')
        metadata_paths.each do |path|
          metadata = Pathname.new(path)
          object = metadata.parent.parent
          data = YAML.load_file(path)
          data['DateDigitized'] = date_digitized
          data['DigiBatch'] = batch.basename.to_s
          pages = Dir.glob("#{object}/*.tif").size
          data['Pages'] = pages
          File.open("#{object}/metadata/#{object.basename}_metadata.txt", 'w') { |file| file.write(data.to_yaml) }
          File.delete(path)
          dest_path = "#{config.fetch(:ocrInput)}/#{object.basename}"
          FileUtils.mv object, dest_path
          bar.increment
        end
        FileUtils.remove_dir "#{batchstr}/Output"
        original_metadata_paths = Dir.glob("#{batchstr}/**/metadata.txt")
        original_metadata_paths.each { |path| File.delete(path) }
        FileUtils.mv batch, "#{config.fetch(:pmArchive)}/#{batch.basename}"
        log.info("#{TDD.timestamp} : archived Digi batch #{batch.basename} with #{batch_size} objects")
        puts pastel.green('Archiving Complete')
        prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
        function = TDD.main_menu
        execute function, config, log
      else
        function = TDD.main_menu
        execute function, config, log
      end
    end

  when 'archiveOCRBatch'
    batch = Time.now.strftime('%Y%m%d')
    input_paths = Pathname.new(config.fetch(:ocrInput)).children
    output_paths = Pathname.new(config.fetch(:ocrOutput)).children
    if input_paths.size == output_paths.size
      response = prompt.select("Archive #{input_paths.size} objects in OCR Batch #{pastel.yellow(batch)}?", %w[Yes No])
      if response == 'Yes'
        input_dirs = []
        output_dirs = []
        input_paths.each { |path| input_dirs << path.basename.to_s }
        output_paths.each { |path| output_dirs << path.basename.to_s }
        if input_dirs.frequency == output_dirs.frequency
          total = input_paths.size + output_paths.size
          bar = ProgressBar.create(total: total, format: 'Archiving OCR Batch: %c/%C |%W| %a')
          FileUtils.mkdir_p "#{config.fetch(:acArchive)}/#{batch}"
          FileUtils.mkdir_p "#{config.fetch(:ocrPostProcess)}/#{batch}"
          input_metadata = {}
          output_metadata = {}
          input_paths.each do |path|
            input_files = []
            id = path.basename.to_s
            input_file_paths = path.children
            input_file_paths.each { |file| input_files << file.basename.to_s }
            input_metadata[id] = input_files
            FileUtils.mv path, "#{config.fetch(:acArchive)}/#{batch}/#{id}"
            bar.increment
          end
          output_paths.each do |path|
            output_files = []
            id = path.basename.to_s
            output_file_paths = path.children
            output_file_paths.each { |file| output_files << file.basename.to_s }
            output_metadata[id] = output_files
            FileUtils.mv path, "#{config.fetch(:ocrPostProcess)}/#{batch}/#{id}"
            bar.increment
          end
          spinner = TDD.new_spinner('Writing Batch Metadata')
          store = YAML::Store.new("#{config.fetch(:stats)}/tdd.yaml")
          store.transaction do
            store[batch] = {
              'ac_archive' => input_metadata,
              'to_metadata' => output_metadata
            }
            store.commit
          end
          log.info("#{TDD.timestamp} : archived OCR batch #{batch} with #{input_paths.size} objects")
          spinner.success(pastel.green('Archiving Complete'))
          prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
          function = TDD.main_menu
          execute function, config, log
        else
          puts 'The identifiers in the Input & Output directories do not match.'
          puts 'Please check the directories and try again.'
          prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
          function = TDD.main_menu
          execute function, config, log
        end
      else
        function = TDD.main_menu
        execute function, config, log
      end
    else
      puts 'The number of folders in the Input & Output directories do not match.'
      puts 'Please check the directories and try again.'
      prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
      function = TDD.main_menu
      execute function, config, log
    end

  when 'processOCRBatch'
    MiniExiftool.command = config.fetch(:exifTool)
    function_path = Pathname.new(config.fetch(:ocrPostProcess))
    choices = TDD.get_choices function_path
    batch = prompt.select('Select OCR Batch:', choices, per_page: 15)
    if batch == 'Main Menu'
      function = TDD.main_menu
      execute function, config, log
    else
      response = prompt.select("Process Batch #{pastel.yellow(batch.basename)}?", %w[Yes No])
      if response == 'Yes'
        puts pastel.yellow("Processing Batch #{pastel.yellow(batch.basename)} ...")
        # bar = ProgressBar.create(total: batch.children.size, format: 'Processing OCR Batch: %c/%C |%W| %a')
        batch.children.each_with_index do |volume,i|
          metadata = YAML.load_file(volume.join('metadata', "#{volume.basename.to_s}_metadata.txt"))
          pdf = volume.join("#{volume.basename.to_s}.pdf")
          TDD.add_exif(pdf, metadata, "#{i+1}/#{batch.children.size}")
          # bar.increment
        end
        log.info("#{TDD.timestamp} : processed OCR batch #{batch.basename} with #{batch.children.size} objects")
        FileUtils.mv batch, "#{config.fetch(:toMetadata)}/#{batch.basename}"
        puts pastel.green('Processing Complete')
        prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
        function = TDD.main_menu
        execute function, config, log
      else
        function = TDD.main_menu
        execute function, config, log
      end
    end

  when 'getMetaNotes'
    function_path = Pathname.new(config.fetch(:toMetadata))
    notes_path = function_path.join('0_Documentation','notes')
    spinner = TDD.new_spinner('Getting Metadata Notes')
    spinner.auto_spin
    metadata_paths = Dir.glob("#{function_path.to_s.gsub('\\', '/')}/**/*_metadata.txt")
    time = TDD.timestamp
    invalid = []
    headers = %w[Directory OCLC DigiNote MetaNote RightsNote]
    CSV.open("#{notes_path}/notes_#{time}.csv", 'w') do |csv|
      csv << headers
      metadata_paths.each do |path|
        parent = Pathname.new(path).parent.parent
        directory, oclc = parent.split
        row = [directory, oclc]
        begin
          metadata = YAML.load_file(path)
        rescue StandardError => e
          invalid << path
          log.error "#{e}"
          next
        end
        row << metadata['DigiNote']
        row << metadata['MetaNote']
        row << metadata['RightsNote']
        csv << row
      end
    end
    spinner.success(pastel.green("Notes Report: #{notes_path}/notes_#{time}.csv"))
    if invalid.size > 0
      file_names = []
      invalid.each {|path| file_names << Pathname.new(path).basename.to_s }
      if invalid.size == 1
        err = 'error'
      else
        err = 'errors'
      end
      puts pastel.red("Found #{invalid.size} metadata validation #{err}: #{file_names}")
    end
    prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
    function = TDD.main_menu
    execute function, config, log

  when 'metadataValidation'
    function_path = Pathname.new(config.fetch(:toMetadata))
    metadata_paths = Dir.glob("#{function_path.to_s.gsub('\\', '/')}/**/*_metadata.txt")
    time = TDD.timestamp
    validation_errors = []
    spinner = TDD.new_spinner('Validating Metadata Files')
    spinner.auto_spin
    metadata_paths.each do |path|
      begin
        metadata = YAML.load_file(path)
      rescue
        validation_errors << path
      end      
    end
    if validation_errors.size > 0
      errors_path = "#{function_path}/0_Documentation/validation/validation_errors_#{time}.txt"
      File.open(errors_path, "w+") do |f|
        f.puts(validation_errors)
      end
      if validation_errors.size == 1
        e = "Error"
      else
        e = "Errors"
      end
      log.info("#{TDD.timestamp} : validated metadata with #{validation_errors.size} #{e}: #{errors_path}")
      spinner.success(pastel.red("Found #{validation_errors.size} #{e}: #{errors_path}"))
    else
      log.info("#{TDD.timestamp} : validated metadata with no errors")
      spinner.success(pastel.green("No YAML Validation Errors Found"))
    end
    prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
    function = TDD.main_menu
    execute function, config, log

  when 'packageIngest'
    response = prompt.select("Please select ingest package type:", ['Open Access', 'Cougarnet', 'Cancel'])
    case response
    when 'Cancel'
      function = TDD.main_menu
      execute function, config, log
    when 'Open Access'
      function_path = Pathname.new(config.fetch(:packageIngest)).join('1_open_access')
      access_type = 'Open Access'
      access_type_short = 'OA'
    when 'Cougarnet'
      function_path = Pathname.new(config.fetch(:packageIngest)).join('2_cougarnet')
      access_type = 'Cougarnet'
      access_type_short = 'CN'
    end
    metadata_paths = Dir.glob("#{function_path.to_s.gsub('\\', '/')}/**/*_metadata.txt")
    rights_errors = []
    metadata_paths.each do |path|
      metadata = YAML.load_file(path)
      case metadata['dc.rights']
      when 'In Copyright'
        next
      when 'No Copyright'
        next
      else
        rights_errors << "#{path} : #{metadata['dc.rights']}"
      end
    end
    if rights_errors.size > 0
      if rights_errors.size == 1
        s = 'statement'
      else
        s = 'statements'
      end
      puts pastel.red("Unknown rights #{s} found:")
      rights_errors.each {|error| puts pastel.yellow(error)}
      prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
      function = TDD.main_menu
      execute function, config, log
    end
    objects = function_path.children
    response = prompt.select("Prepare #{objects.size} #{access_type} volumes for ingest?", %w[Yes No])
    if response == 'Yes'
      archive_path = config.fetch(:packageArchive)
      output_path = config.fetch(:packageOutput)
      batch_name = "#{access_type_short}_#{TDD.timestamp}"
      archive_dir = "#{archive_path}/#{batch_name}"
      batch_dir = "#{output_path}/#{batch_name}"
      FileUtils.mkdir_p archive_dir
      FileUtils.mkdir_p batch_dir
      headers = TDD.headers
      admin_fields = TDD.admin_fields
      bar = ProgressBar.create(total: objects.size, format: 'Preparing Ingest Batch: %c/%C |%W| %a')
      CSV.open("#{batch_dir}/#{batch_name}.csv", 'w') do |csv|
        csv << headers
        objects.each do |object|
          metadata = []
          meta_txt = object.join('metadata', "#{object.basename.to_s}_metadata.txt")
          pdf = "#{object.basename.to_s}.pdf"
          YAML.load_file(meta_txt).each do |k,v|
            unless admin_fields.include? k
              if k == 'dc.rights'
                case v
                when 'No Copyright'
                  v = 'All original thesis material contained in this document is presumed in the public domain according to the terms of the UH Libraries'' Retrospective Thesis and Dissertation Scanning Policy. Any material not created by the author may be protected by copyright but is made available here under a claim of fair use (17 U.S.C. Section 107) for non-profit research and educational purposes. The University of Houston Libraries respects the intellectual property rights of others and does not claim any copyright interest in any component of this item. Users of this work assume the responsibility for determining copyright status prior to reusing, publishing, or reproducing this item for purposes other than what is allowed by fair use or other copyright exemptions. Any reuse of this item in excess of fair use or other copyright exemptions requires permission of the copyright holder. The University of Houston Libraries would like to learn more about this item and invites individuals or organizations to contact the project team (cougarroar@uh.edu) with any additional information they can provide.'
                when 'In Copyright'
                  v = 'The University of Houston Libraries respects the intellectual property rights of others and do not claim any copyright interest in this item. This item may be protected by copyright but is made available here under a claim of fair use (17 U.S.C. Section 107) for non-profit research and educational purposes. Users of this work assume the responsibility for determining copyright status prior to reusing, publishing, or reproducing this item for purposes other than what is allowed by fair use or other copyright exemptions. Any reuse of this item in excess of fair use or other copyright exemptions requires permission of the copyright holder. The University of Houston Libraries would like to learn more about this item and invites individuals or organizations to contact the project team (cougarroar@uh.edu) with any additional information they can provide.'
                end
              end
              metadata << v
            end
          end
          creator = metadata[3].strip.split(',')[0]
          date = metadata[5].strip
          pdf_new = creator + '_' + date + '_' + pdf
          FileUtils.cp object.join(pdf), "#{batch_dir}/#{pdf_new}"
          csv << [pdf_new] + metadata
          FileUtils.mv object, "#{archive_dir}/#{object.basename}"
          bar.increment
        end
      end
      log.info("#{TDD.timestamp} : packaged #{objects.size} #{access_type} objects for ingest")
      puts pastel.green('Packaging Complete')
      prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
      function = TDD.main_menu
      execute function, config, log
    else
      function = TDD.main_menu
      execute function, config, log
    end

  when 'Statistics'
    choices = ['.. Main Menu', 'Digi Production', 'Completed Volumes']
    response = prompt.select('Choose a report:', choices)
    case response
    when 'Digi Production'
      print pastel.yellow('Getting Images ... ')
      path = Pathname.new(config.fetch(:acArchive))
      images = TDD.get_images(path)
      puts pastel.green("Found #{images.size}")
      print pastel.yellow('Writing Report ... ')
      report = Time.now.strftime('%Y%m%d')
      report_path = Pathname.new(config.fetch(:stats))
      report_path = report_path.join('digi', "#{report}.txt")
      stats = {}
      stats['Project Total'] = images.size
      duplicates = []
      images.each do |filename, paths|
        paths.each do |path|
          t = File.ctime(path)
          if stats[t.year].nil?
            stats[t.year] = { 'Year Total' => 1, t.month => 1 }
          else
            if stats[t.year][t.month].nil?
              stats[t.year]['Year Total'] += 1
              stats[t.year].store(t.month, 1)
            else
              stats[t.year]['Year Total'] += 1
              stats[t.year][t.month] += 1
            end
          end
        end
        duplicates << { filename => paths } if paths.size > 1
      end
      stats['Duplicates'] = duplicates
      File.write(report_path, stats.to_yaml)
      puts pastel.green("Compiled #{report}.txt")
      prompt.keypress('Press Space or Return to continue ...', keys: %i[space return])
      function = TDD.main_menu
      execute function, config, log

    when 'Digitized Volumes'

    when '.. Main Menu'
      function = TDD.main_menu
      execute function, config, log
    end

  when 'Quit'
    response = prompt.select('Do you really want to quit?', %w[Yes No])
    if response == 'Yes'
      exit
    else
      function = TDD.main_menu
      execute function, config, log
    end
  end
end

config = TTY::Config.new
config.filename = 'paths'
config.append_path "P:/DigitalProjects/_TDD/0_dev/workflow"
config.read
log = Logger.new "P:/DigitalProjects/_TDD/0_dev/workflow/tdd-workflow-utility.log"
log.level = Logger::INFO

pastel = Pastel.new
print TTY::Box.frame(
  align: :center,
  border: :thick,
  style: {
    border: {
      fg: :red
    }
  }
) { pastel.bold('TDD Workflow Utility') }
function = TDD.main_menu
execute(function, config, log)