module Crystal
  class Type
    include Enumerable

    def metaclass
      @metaclass ||= Metaclass.new(self)
    end

    def eql?(other)
      self == other
    end

    def each
      yield self
    end

    def passed_as_self?
      true
    end

    def self.merge(*types)
      all_types = types.map { |type| type.is_a?(UnionType) ? type.types.to_a : type }.flatten.compact.uniq(&:object_id)
      if all_types.length == 0
        nil
      elsif all_types.length == 1
        all_types.first
      else
        union = UnionType.new(*all_types)
        types.each do |t|
          return t if t == union
        end
        union
      end
    end

    def self.clone(types)
      types_context = {}
      types.map { |type| type.clone(types_context) }
    end

    def self.relationship(types)
      path = []
      relationships = []
      known_paths = {}

      types.each_with_index do |type, i|
        path.push i
        relationships.push type.relationship(known_paths, path)
        path.pop
      end

      relationships
    end
  end

  class ContainerType < Type
    attr_accessor :types

    def initialize
      @types = {}
    end
  end

  class ClassType < ContainerType
    attr_reader :parent_type
    attr_reader :name
    attr_accessor :defs

    def initialize(name, parent_type)
      super()
      @name = name
      @parent_type = parent_type
      @defs = parent_type ? HashWithParent.new(parent_type.defs) : {}
    end
  end

  class PrimitiveType < ClassType
    attr_reader :name
    attr_reader :llvm_type
    attr_reader :llvm_size

    def initialize(name, parent_type, llvm_type, llvm_size)
      super(name, parent_type)
      @llvm_type = llvm_type
      @llvm_size = llvm_size
    end

    def ==(other)
      equal?(other) || (other.is_a?(UnionType) && other == self)
    end

    def llvm_name
      name
    end

    def to_s
      name
    end

    def clone(*)
      self
    end

    def relationship(*)
      self
    end
  end

  module MutableType
    def observe_mutations(&block)
      @mutation_observers ||= {}
      token = block.object_id
      @mutation_observers[token] = block
      token
    end

    def unobserve_mutations(token)
      @mutation_observers.delete token
      @mutation_observers = nil if @mutation_observers.empty?
    end
  end

  module RelatableType
    def relationship(known_paths = {}, path = [])
      known_path = known_paths[object_id]
      if known_path
        return Path.new(*known_path)
      end

      known_paths[object_id] = path.dup

      relationship_object(known_paths, path)
    end
  end

  module MutableClassType
    include MutableType

    def mutation(ivar)
      hook_to_ivar_mutations(ivar)

      return unless @mutation_observers
      @mutation_observers.values.each do |observer|
        observer.call([ivar], ivar.type)
      end
    end

    def hook_to_ivar_mutations(ivar)
      if @ivar_tokens && (type_and_token = @ivar_tokens[ivar.name])
        type_and_token[0].unobserve_mutations(type_and_token[1])
      end

      if ivar.type.is_a?(MutableType)
        token = ivar.type.observe_mutations do |sub_ivar, type|
          if @mutation_observers && !sub_ivar.map(&:object_id).include?(ivar.object_id)
            @mutation_observers.values.each do |observer|
              observer.call([ivar] + sub_ivar, type)
            end
          end
        end

        @ivar_tokens ||= {}
        @ivar_tokens[ivar.name] = [ivar.type, token]
      end
    end
  end

  class ObjectType < ClassType
    include MutableClassType
    include RelatableType

    attr_accessor :instance_vars
    @@id = 0

    def initialize(name, parent_type = nil)
      super
      @instance_vars = {}
    end

    def metaclass
      @metaclass ||= begin
        metaclass = Metaclass.new(self)
        metaclass.defs['alloc'] = Def.new('alloc', [], Alloc.new(self))
        metaclass
      end
    end

    def lookup_instance_var(name)
      var = @instance_vars[name]
      unless var
        var = Var.new name
        var.add_observer self, :mutation
        @instance_vars[name] = var
      end
      var
    end

    def ==(other)
      equal?(other) ||
        (other.is_a?(ObjectType) && name == other.name && instance_vars == other.instance_vars) ||
        (other.is_a?(UnionType) && other == self)
    end

    def hash
      name.hash
    end

    def llvm_type
      @llvm_type ||= LLVM::Pointer(llvm_struct_type)
    end

    def llvm_size
      Crystal::Module::POINTER_SIZE
    end

    def llvm_struct_type
      unless @llvm_struct_type
        @llvm_struct_type = LLVM::Struct(llvm_name)
        @llvm_struct_type.element_types = @instance_vars.values.map(&:llvm_type)
      end
      @llvm_struct_type
    end

    def llvm_name
      @id ||= (@@id += 1)
      "#{name}#{@id}"
    end

    def index_of_instance_var(name)
      @instance_vars.keys.index(name)
    end

    def clone(types_context = {}, nodes_context = {})
      obj = types_context[object_id] and return obj

      obj = types_context[object_id] = ObjectType.new name, @parent_type
      obj.instance_vars = Hash[instance_vars.map do |name, var|
        cloned_var = var.clone(nodes_context)
        cloned_var.type = var.type.clone(types_context, nodes_context) if var.type
        obj.hook_to_ivar_mutations(cloned_var)
        cloned_var.bind_to cloned_var
        cloned_var.add_observer obj, :mutation
        [name, cloned_var]
      end]
      obj.defs = defs
      obj
    end

    def relationship_object(known_paths = {}, path = [])
      obj = ObjectType.new(name)
      instance_vars.each do |name, var|
        if var.type
          path.push name

          obj.lookup_instance_var(name).set_type var.type.relationship(known_paths, path)

          path.pop
        end
      end
      obj
    end

    def to_s
      return @to_s if @to_s
      @to_s = "..."
      instance_vars_to_s = instance_vars.map {|name, var| "#{name}: #{var.type}"}.join ', '
      @to_s = nil
      "#{name}<#{instance_vars_to_s}>"
    end
  end

  class ArrayType < ClassType
    include MutableClassType
    include RelatableType

    attr_accessor :vars
    @@id = 0

    def initialize(parent_type = nil, var = Var.new('element'))
      super("Array", parent_type)
      var.add_observer self, :mutation
      @vars = [var]
    end

    def lookup_instance_var(name)
      @vars[0]
    end

    def element_type_var
      @vars[0]
    end

    def element_type_var=(x)
      @vars[0] = x
    end

    def element_type
      element_type_var.type
    end

    def ==(other)
      equal?(other) ||
        (other.is_a?(ArrayType) && vars == other.vars) ||
        (other.is_a?(UnionType) && other == self)
    end

    def hash
      1
    end

    def clone(types_context = {}, nodes_context = {})
      array = types_context[object_id] and return array

      cloned_element_type_var = element_type_var.clone(nodes_context)

      array = types_context[object_id] = ArrayType.new @parent_type, cloned_element_type_var
      array.element_type_var.type = element_type.clone(types_context, nodes_context)
      array.element_type_var.bind_to array.element_type_var if array.element_type
      array.defs = defs
      array
    end

    def relationship_object(known_paths = {}, path = [])
      array = ArrayType.new
      if element_type
        path.push element_type_var.name

        array.element_type_var.set_type element_type.relationship(known_paths, path)

        path.pop
      end
      array
    end

    def llvm_type
      @llvm_type ||= element_type ? LLVM::Pointer(llvm_struct_type) : LLVM::Int1
    end

    def llvm_struct_type
      unless @llvm_struct_type
        @llvm_struct_type = LLVM::Struct(llvm_name)
        @llvm_struct_type.element_types = [LLVM::Int, LLVM::Int, LLVM::Pointer(element_type.llvm_type)]
      end
      @llvm_struct_type
    end

    def llvm_size
      4 + 4 + Crystal::Module::POINTER_SIZE
    end

    def llvm_name
      @id ||= (@@id += 1)
      "Array#{@id}"
    end

    def to_s
      return @to_s if @to_s
      @to_s = "..."
      name = "Array<#{element_type || 'Void'}>"
      @to_s = nil
      name
    end
  end

  class UnionType < Type
    include MutableType
    include RelatableType

    attr_reader :types

    def initialize(*types)
      @types = types
      types.each_with_index do |type, index|
        if type.is_a?(MutableType)
          type.observe_mutations do |ivar, type|
            if @mutation_observers
              @mutation_observers.values.each do |observer|
                observer.call([index] + ivar, type)
              end
            end
          end
        end
      end
    end

    def set_with_count
      hash = Hash.new(0)
      @types.each do |type|
        hash[type] += 1
      end
      hash
    end

    def llvm_type
      unless @llvm_type
        @llvm_type = LLVM::Struct(llvm_name)
        @llvm_type.element_types = [LLVM::Int, LLVM::Type.array(LLVM::Int8, llvm_value_size)]
      end
      @llvm_type
    end

    def llvm_name
      "[#{types.map(&:llvm_name).join ', '}]"
    end

    def llvm_size
      @llvm_size ||= llvm_value_size + 4
    end

    def llvm_value_size
      @llvm_value_size ||= @types.map(&:llvm_size).max
    end

    def index_of_type(type)
      @types.index type
    end

    def each(&block)
      types.each(&block)
    end

    def hash
      set_with_count.hash
    end

    def ==(other)
      return true if equal?(other)

      if @types.length == 1
        @types.first == other
      elsif other.is_a?(UnionType)
        @types.length == other.types.length && set_with_count == other.set_with_count
      else
        false
      end
    end

    def clone(types_context = {}, nodes_context = {})
      cloned = types_context[object_id] and return cloned
      types_context[object_id] = UnionType.new(*types.map { |type| type.clone(types_context, nodes_context) })
    end

    def relationship_object(known_paths = {}, path = [])
      union = UnionType.new
      types.each_with_index do |type, i|
        path.push i
        union.types.push type.relationship(known_paths, path)
        path.pop
      end
      union
    end

    def name
      "Union"
    end

    def to_s
      "Union[#{types.join ', '}]"
    end
  end

  class Metaclass < Type
    attr_reader :name
    attr_reader :type
    attr_reader :defs

    def initialize(type)
      @name = "#{type.name}:Metaclass"
      @type = type
      @defs = {}
    end

    def passed_as_self?
      false
    end

    def instance_type
      type
    end
  end

  class LibType < ContainerType
    attr_accessor :name
    attr_accessor :libname
    attr_accessor :defs

    def initialize(name, libname = nil)
      super()
      @name = name
      @libname = libname
      @defs = {}
    end

    def metaclass
      self
    end

    def fun(name, args, return_type)
      args = args.map { |name, type| Var.new(name, type) }

      instance = @defs[name] = External.new(name, args)
      instance.body = Expressions.new
      instance.body.set_type(return_type)
      instance.add_instance instance
    end

    def passed_as_self?
      false
    end

    def ==(other)
      other.is_a?(LibType) && other.name == name && other.libname == libname
    end

    def to_s
      "LibType(#{name}, #{libname})"
    end
  end

  class TypeDefType < Type
    attr_accessor :name
    attr_accessor :type

    def initialize(name, type)
      @name = name
      @type = type
    end

    def ==(other)
      other.is_a?(TypeDefType) && other.name == name && other.type == type
    end

    def llvm_type
      type.llvm_type
    end

    def llvm_name
      type.llvm_name
    end

    def instance_type
      self
    end

    def clone(*)
      self
    end

    def relationship(*)
      self
    end

    def to_s
      name
    end
  end

  class StructType < Type
    attr_accessor :name
    attr_accessor :vars
    attr_accessor :defs

    def initialize(name, vars)
      @name = name
      @vars = Hash[vars.map { |var| [var.name, var] }]
      @defs = {}
      @vars.keys.each do |var_name|
        @defs["#{var_name}="] = Def.new("#{var_name}=", [Var.new('value')], StructSet.new(var_name))
        @defs[var_name] = Def.new(var_name, [], StructGet.new(var_name))
      end
    end

    def metaclass
      @metaclass ||= begin
        metaclass = Metaclass.new(self)
        metaclass.defs['new'] = Def.new('new', [], StructAlloc.new(self))
        metaclass
      end
    end

    def ==(other)
      other.is_a?(StructType) && other.name == name && other.vars == vars
    end

    def instance_type
      self
    end

    def clone(*)
      self
    end

    def relationship(*)
      self
    end

    def to_s
      return @to_s if @to_s
      @to_s = "..."
      vars_to_s = vars.map {|name, var| "#{name}: #{var.type}"}.join ', '
      @to_s = nil
      "#{name}<#{vars_to_s}>"
    end
  end
end