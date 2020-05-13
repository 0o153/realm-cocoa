#!/usr/bin/ruby

require 'net/http'

ROOT_DIR="#{Dir.pwd}/../.."
MONGO_DIR="#{ROOT_DIR}/build/mongodb-*"

def run_mongod
    puts "starting mongod..."
    `#{MONGO_DIR}/bin/mongod --quiet \
        --dbpath #{MONGO_DIR}/db_files \
        --bind_ip localhost \
        --port 26000 \
        --replSet test \
        --fork --logpath #{MONGO_DIR}/mongod.log`
    puts "mongod starting"

    retries = 0
    begin
        Net::HTTP.get(URI('http://localhost:26000'))
    rescue => exception
        sleep(1)
        retries += 1
        if retries == 5
            abort('could not connect to mongod')
        end
    end

    puts "mongod started"
end

def shutdown_mongod
    puts 'shutting down mongod'
    `#{MONGO_DIR}/bin/mongo --port 26000 admin --eval "db.adminCommand({replSetStepDown: 0, secondaryCatchUpPeriodSecs: 0, force: true})"`
    `#{MONGO_DIR}/bin/mongo --port 26000 admin --eval "db.shutdownServer({force: true})"`
end

def run_stitch
    current_dir = Dir.pwd
    root_dir = "#{current_dir}/../.."
    stitch_path = "#{root_dir}/stitch"

    exports = []
    if Dir.exist?("#{root_dir}/go")
        exports << "export GOROOT=#{root_dir}/go"
        exports << "export PATH=$GOROOT/bin:$PATH"
    end

    exports << "export STITCH_PATH=\"#{root_dir}/stitch\""
    exports << "PATH=\"$PATH:$STITCH_PATH/etc/transpiler/bin\""
    exports << "export LD_LIBRARY_PATH=\"$STITCH_PATH/etc/dylib/lib\""
    
    puts 'starting baas'

    pid = Process.fork {
        `#{exports.join(' && ')} && \
        cd #{stitch_path} && \
        go run -exec "env LD_LIBRARY_PATH=#{stitch_path}/etc/dylib/lib" #{stitch_path}/cmd/server/main.go --configFile "#{stitch_path}/etc/configs/test_config.json"`
    }
    Process.detach(pid)
    retries = 0
    begin
        Net::HTTP.get(URI('http://localhost:9090'))
    rescue => exception
        sleep(1)
        retries += 1
        if retries == 50
            abort('could not connect to baas')
        end
        retry
    end
end

def shutdown_stitch
    puts 'shutting down baas'
    `pkill -9 stitch`
    `pkill -9 ruby`
end

def start
    run_mongod
    run_stitch
end

def shutdown
    shutdown_stitch
    shutdown_mongod
end

if ARGV.length < 1
    abort("Too few arguments")
end

case ARGV[0]
when "start" 
    start
when "shutdown" 
    shutdown
end
