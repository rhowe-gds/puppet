if __FILE__ == $0
    $:.unshift '../../lib'
    $:.unshift '..'
    $puppetbase = "../.."
end

require 'puppet'
require 'puppet/parser/parser'
require 'test/unit'
require 'puppettest'

class TestParser < Test::Unit::TestCase
	include ParserTesting
    def setup
        super
        Puppet[:parseonly] = true
        #@lexer = Puppet::Parser::Lexer.new()
        @parser = Puppet::Parser::Parser.new()
    end

    def test_each_file
        textfiles { |file|
            Puppet.debug("parsing %s" % file) if __FILE__ == $0
            assert_nothing_raised() {
                @parser.file = file
                @parser.parse
            }

            Puppet::Type.eachtype { |type|
                type.each { |obj|
                    assert(obj.file)
                    assert(obj.name)
                    assert(obj.line)
                }
            }
            Puppet::Type.allclear
        }
    end

    def test_failers
        failers { |file|
            Puppet.debug("parsing failer %s" % file) if __FILE__ == $0
            assert_raise(Puppet::ParseError) {
                @parser.file = file
                ast = @parser.parse
                Puppet::Parser::Scope.new.evaluate(:ast => ast)
            }
            Puppet::Type.allclear
        }
    end

    def test_arrayrvalues
        parser = Puppet::Parser::Parser.new()
        ret = nil
        file = tempfile()
        assert_nothing_raised {
            parser.string = "file { \"#{file}\": mode => [755, 640] }"
        }

        assert_nothing_raised {
            ret = parser.parse
        }
    end

    def mkmanifest(file)
        name = File.join(tmpdir, "file%s" % rand(100))
        @@tmpfiles << name

        File.open(file, "w") { |f|
            f.puts "file { \"%s\": ensure => file, mode => 755 }\n" %
               name
        }
    end

    def test_importglobbing
        basedir = File.join(tmpdir(), "importesting")
        @@tmpfiles << basedir
        Dir.mkdir(basedir)

        Puppet[:lib] = [basedir]

        subdir = "subdir"
        Dir.mkdir(File.join(basedir, subdir))
        manifest = File.join(basedir, "manifest")
        File.open(manifest, "w") { |f|
            f.puts "import \"%s/*\"" % subdir
        }

        4.times { |i|
            path = File.join(basedir, subdir, "subfile%s" % i)
            mkmanifest(path)
        }

        assert_nothing_raised("Could not parse multiple files") {
            parser = Puppet::Parser::Parser.new()
            #parser.import("#{subdir}/*")
            parser.file = manifest
            parser.parse
        }
    end

    def test_defaults
        basedir = File.join(tmpdir(), "defaulttesting")
        @@tmpfiles << basedir
        Dir.mkdir(basedir)

        defs1 = {
            "testing" => "value"
        }

        defs2 = {
            "one" => "two",
            "three" => "four",
            "five" => false,
            "seven" => "eight",
            "nine" => true,
            "eleven" => "twelve"
        }

        mkdef = proc { |hash|
            hash.collect { |arg, value|
                "$%s = %s" % [arg, value]
            }.join(", ")
        }
        manifest = File.join(basedir, "manifest")
        File.open(manifest, "w") { |f|
            f.puts "
    define method(#{mkdef.call(defs1)}, $other) {
        $variable = $testing
    }

    define othermethod(#{mkdef.call(defs2)}, $goodness) {
        $more = less
    }

    method {
        other => yayness
    }

    othermethod {
        goodness => rahness
    }
"

        }

        ast = nil
        assert_nothing_raised("Could not parse multiple files") {
            parser = Puppet::Parser::Parser.new()
            parser.file = manifest
            ast = parser.parse
        }

        assert(ast, "Did not receive AST while parsing defaults")

        scope = nil
        assert_nothing_raised("Could not evaluate defaults parse tree") {
            scope = Puppet::Parser::Scope.new()
            scope.name = "parsetest"
            scope.type = "parsetest"
            objects = scope.evaluate(:ast => ast)
        }

        method = nil
        othermethod = nil
        assert_nothing_raised {
            method = scope.find { |child|
                child.is_a?(Puppet::Parser::Scope) and child.type == "method"
            }
            defs1.each { |var, value|
                curval = method.lookupvar(var)
                assert_equal(value, curval, "Did not get default")
            }
        }

        assert_nothing_raised {
            method = scope.find { |child|
                child.is_a?(Puppet::Parser::Scope) and child.type == "othermethod"
            }
            defs2.each { |var, value|
                curval = method.lookupvar(var)
                assert_equal(value, curval, "Did not get default")
            }
        }
    end

    def test_trailingcomma
        path = tempfile()
        str = %{file { "#{path}": ensure => file, }
        }

        parser = Puppet::Parser::Parser.new
        parser.string = str

        assert_nothing_raised("Could not parse trailing comma") {
            parser.parse
        }
    end

    def test_importedclasses
        imported = tempfile()
        importer = tempfile()

        made = tempfile()

        File.open(imported, "w") do |f|
            f.puts %{class foo { file { "#{made}": ensure => file }}}
        end

        File.open(importer, "w") do |f|
            f.puts %{import "#{imported}"\ninclude foo}
        end

        parser = Puppet::Parser::Parser.new
        parser.file = importer

        # Make sure it parses fine
        assert_nothing_raised {
            parser.parse
        }

        # Now make sure it actually does the work
        assert_creates(importer, made)
    end

    # Make sure fully qualified and unqualified files can be imported
    def test_fqfilesandlocalfiles
        dir = tempfile()
        Dir.mkdir(dir)
        Puppet[:lib] = [dir]
        importer = File.join(dir, "site.pp")
        fullfile = File.join(dir, "full.pp")
        localfile = File.join(dir, "local.pp")

        files = []

        File.open(importer, "w") do |f|
            f.puts %{import "#{fullfile}"\ninclude full\nimport "local.pp"\ninclude local}
        end

        fullmaker = tempfile()
        files << fullmaker

        File.open(fullfile, "w") do |f|
            f.puts %{class full { file { "#{fullmaker}": ensure => file }}}
        end

        localmaker = tempfile()
        files << localmaker

        File.open(localfile, "w") do |f|
            f.puts %{class local { file { "#{localmaker}": ensure => file }}}
        end

        parser = Puppet::Parser::Parser.new
        parser.file = importer

        # Make sure it parses
        assert_nothing_raised {
            parser.parse
        }

        # Now make sure it actually does the work
        assert_creates(importer, *files)
    end

    # Make sure that file importing changes file relative names.
    def test_changingrelativenames
        dir = tempfile()
        Dir.mkdir(dir)
        Puppet[:lib] = [dir]
        Dir.mkdir(File.join(dir, "subdir"))
        top = File.join(dir, "site.pp")
        subone = File.join(dir, "subdir/subone")
        subtwo = File.join(dir, "subdir/subtwo")

        files = []
        file = tempfile()
        files << file

        File.open(subone + ".pp", "w") do |f|
            f.puts %{class one { file { "#{file}": ensure => file }}}
        end

        otherfile = tempfile()
        files << otherfile
        File.open(subtwo + ".pp", "w") do |f|
            f.puts %{import "subdir/subone"\n class two inherits one {
                file { "#{otherfile}": ensure => file }
            }}
        end

        File.open(top, "w") do |f|
            f.puts %{import "subdir/subtwo"}
        end

        parser = Puppet::Parser::Parser.new
        parser.file = top

        assert_nothing_raised {
            parser.parse
        }
    end

    # Verify that collectable objects are marked that way.
    def test_collectable
        Puppet[:storeconfigs] = true
        ["@port { ssh: protocols => tcp, number => 22 }",
         "@port { ssh: protocols => tcp, number => 22;
            smtp: protocols => tcp, number => 25 }"].each do |text|
            parser = Puppet::Parser::Parser.new
            parser.string = text

            ret = nil
            assert_nothing_raised {
                ret = parser.parse
            }

            assert_instance_of(AST::ASTArray, ret)

            ret.each do |obj|
                assert_instance_of(AST::ObjectDef, obj)
                assert(obj.collectable, "Object was not marked collectable")
            end
        end
    end

    # Defaults are purely syntactical, so it doesn't make sense to be able to
    # collect them.
    def test_uncollectabledefaults
        string = "@Port { protocols => tcp }"
        parser = Puppet::Parser::Parser.new
        parser.string = string

        assert_raise(Puppet::ParseError) {
            parser.parse
        }
    end

    # Verify that we can parse collections
    def test_collecting
        Puppet[:storeconfigs] = true
        text = "port <| |>"
        parser = Puppet::Parser::Parser.new
        parser.string = text

        ret = nil
        assert_nothing_raised {
            ret = parser.parse
        }

        assert_instance_of(AST::ASTArray, ret)

        ret.each do |obj|
            assert_instance_of(AST::Collection, obj)
        end
    end

    def test_emptyfile
        file = tempfile()
        File.open(file, "w") do |f|
            f.puts %{}
        end
        parser = Puppet::Parser::Parser.new
        parser.file = file
        assert_nothing_raised {
            parser.parse
        }
    end

    def test_multiple_nodes_named
        file = tempfile()
        other = tempfile()

        File.open(file, "w") do |f|
            f.puts %{
node nodeA, nodeB {
    file { "#{other}": ensure => file }
    
}
}
        end

        parser = Puppet::Parser::Parser.new
        parser.file = file
        ast = nil
        assert_nothing_raised {
            ast = parser.parse
        }
    end

    def test_emptyarrays
        str = %{$var = []\n}

        parser = Puppet::Parser::Parser.new
        parser.string = str

        # Make sure it parses fine
        assert_nothing_raised {
            parser.parse
        }
    end

    # Make sure function names aren't reserved words.
    def test_functionnamecollision
        str = %{tag yayness
tag(rahness)

file { "/tmp/yayness":
    tag => "rahness",
    ensure => exists
}
}
        parser = Puppet::Parser::Parser.new
        parser.string = str

        # Make sure it parses fine
        assert_nothing_raised {
            parser.parse
        }
    end

    def test_metaparams_in_definition_prototypes
        parser = Puppet::Parser::Parser.new

        str1 = %{define mydef($schedule) {}}
        parser.string = str1

        assert_raise(Puppet::ParseError) {
            parser.parse
        }

        str2 = %{define mydef($schedule = false) {}}
        parser.string = str2

        assert_raise(Puppet::ParseError) {
            parser.parse
        }

        str3 = %{define mydef($schedule = daily) {}}
        parser.string = str3

        assert_nothing_raised {
            parser.parse
        }
    end

    def test_parsingif
        parser = Puppet::Parser::Parser.new()
        exec = proc do |val|
            %{exec { "/bin/echo #{val}": logoutput => true }}
        end
        str1 = %{if true { #{exec.call("true")} }}
        ret = nil
        assert_nothing_raised {
            ret = parser.parse(str1)[0]
        }
        assert_instance_of(Puppet::Parser::AST::IfStatement, ret)
        str2 = %{if true { #{exec.call("true")} } else { #{exec.call("false")} }}
        assert_nothing_raised {
            ret = parser.parse(str2)[0]
        }
        assert_instance_of(Puppet::Parser::AST::IfStatement, ret)
        assert_instance_of(Puppet::Parser::AST::Else, ret.else)
    end

    def test_find
        parser = Puppet::Parser::Parser.new()

        dir = tempfile()
        Dir.mkdir(dir)
        name = "file"
        file = File.join(dir, "#{name}.pp")
        File.open(file, "w") { |f| f.puts "" }

        Puppet[:lib] = dir

        [name, name + ".pp", file].each do |f|
            full = nil
            assert_nothing_raised do
                full = parser.class.find(f)
            end

            assert_equal(file, full)
        end

        assert_nil(parser.class.find("nosuchfile"))
    end

    def test_libsetup
        lib = [tempfile, tempfile]
        assert_nothing_raised do
            Puppet[:lib] = lib.join(":")
        end
        env = [tempfile, tempfile]
        assert_nothing_raised do
            ENV["PUPPETLIB"] = env.join(":")
        end

        parser = Puppet::Parser::Parser.new()
        assert_nothing_raised do
            parser.class.libsetup
        end

        old = Puppet[:lib]

        [lib, env].flatten.each do |dir|
            assert(Puppet[:lib].include?(dir), "Did not include %s" % dir)
        end

        assert_nothing_raised do
            parser.class.libsetup
        end

        assert_equal(old, Puppet[:lib], "Libdirs changed on second run")
    end

    def test_glob
        dirs = []
        subdirs = []
        files = []
        subfiles = []
        2.times { |i|
            dir = tempfile()
            dirs << dir

            Dir.mkdir(dir)

            file = File.join(dir, "file.pp")
            File.open(file, "w") { |f| f.puts "" }
            files << file

            subdir = File.join(dir, "subdir")
            Dir.mkdir(subdir)
            subdirs << subdir
            subfile = File.join(subdir, "file.pp")
            File.open(subfile, "w") { |f| f.puts "" }
            subfiles << subfile
        }
        Puppet[:lib] = dirs.join(":")

        klass = Puppet::Parser::Parser

        # Okay, first glob a full path
        dir = dirs[0]
        assert_nothing_raised do
            result = klass.glob("#{dir}/*")

            assert_equal([File.join(dir, "file.pp")], result)
        end

        # Now check it across our search path
        assert_nothing_raised do
            result = klass.glob("file*")

            assert_equal(files, result, "Did not find globbed files")

            result = klass.glob("subdir/*")

            assert_equal(subfiles, result, "Did not find globbed subfiles")
        end

        # Now try it with a normal file.
    end
end

# $Id$
