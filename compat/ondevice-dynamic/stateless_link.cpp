// Prototype of the existing stateless compute closure on the embedded LLVM.
// Includes the ordinary converter once, sharing its bounded reader/fatal scope.
// No Apple compiler, subprocess, network or dependency filesystem search.
#include "HGOnDeviceAIR.cpp"
#include <llvm/Linker/Linker.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/Constants.h>
#include <llvm/Transforms/Utils/ModuleUtils.h>
#include <llvm/Support/Path.h>
#include <functional>
#include <array>

namespace hg_dynamic {
struct Input { const void *bytes; size_t size; const std::set<std::string> *exports = nullptr; };

static std::set<std::string> options(Module &m) {
    std::set<std::string> result;
    auto *metadata = m.getNamedMetadata("air.compile_options");
    need(metadata, "missing AIR compile options");
    for (auto *node : metadata->operands()) {
        need(node->getNumOperands() == 1, "unsupported compile option shape");
        auto *value = dyn_cast_or_null<MDString>(node->getOperand(0));
        need(value, "unsupported compile option value");
        result.insert(value->getString().str());
    }
    return result;
}

static void version(Module &m, StringRef key, unsigned major, unsigned minor) {
    auto *metadata = m.getNamedMetadata(key);
    need(metadata && metadata->getNumOperands() == 1,
         "unsupported AIR version metadata");
    auto *node = metadata->getOperand(0);
    unsigned skip = key == "air.language_version" ? 1 : 0;
    need(node->getNumOperands() == 3 + skip, "unsupported AIR version tuple");
    if (skip) {
        auto *language = dyn_cast_or_null<MDString>(node->getOperand(0));
        need(language && language->getString() == "Metal", "unsupported AIR language");
    }
    unsigned wanted[] = {major, minor, 0};
    for (unsigned i = 0; i != 3; ++i) {
        auto *value = mdconst::dyn_extract_or_null<ConstantInt>(node->getOperand(i + skip));
        need(value && value->getZExtValue() == wanted[i], "unsupported AIR version");
    }
}

// Record imports before dropping routing globals. Every import must resolve to
// a concrete definition after linking. A table with semantic IR users is not
// a stateless closure and is never erased to manufacture successful output.
static void routing(Module &m, std::set<std::string> &imports) {
    std::set<GlobalVariable *> tables;
    for (auto &global : m.globals()) {
        if (!global.getName().startswith("air.dyld_")) continue;
        need(global.getName() == "air.dyld_flat_table" ||
             global.getName() == "air.dyld_lib_table" ||
             global.getName() == "air.dyld_str_table", "unknown AIR routing table");
        tables.insert(&global);
    }
    if (tables.empty()) return;
    auto *flat = m.getNamedGlobal("air.dyld_flat_table");
    need(flat && flat->hasInitializer(), "missing AIR import table");
    auto *array = dyn_cast<ConstantArray>(flat->getInitializer());
    need(array && array->getNumOperands() <= 4096, "unsupported AIR import table");
    for (auto &operand : array->operands()) {
        auto *function = dyn_cast<Function>(operand->stripPointerCasts());
        need(function, "AIR import is not a direct function");
        imports.insert(function->getName().str());
    }
    for (const char *name : {"llvm.used", "llvm.compiler.used"}) {
        auto *used = m.getNamedGlobal(name);
        if (!used) continue;
        auto *values = used->hasInitializer()
            ? dyn_cast<ConstantArray>(used->getInitializer()) : nullptr;
        need(values && used->hasAppendingLinkage() && used->use_empty() &&
             used->getSection() == "llvm.metadata", "unsupported used-list shape");
        std::vector<Constant *> keep;
        for (auto &operand : values->operands()) {
            auto *value = cast<Constant>(operand.get());
            auto *global = dyn_cast<GlobalVariable>(value->stripPointerCasts());
            if (!global || !tables.count(global)) keep.push_back(value);
        }
        Type *element = values->getType()->getElementType();
        used->eraseFromParent();
        if (!keep.empty()) {
            auto *initializer = ConstantArray::get(ArrayType::get(element, keep.size()), keep);
            auto *replacement = new GlobalVariable(m, initializer->getType(), false,
                GlobalValue::AppendingLinkage, initializer, name);
            replacement->setSection("llvm.metadata");
        }
    }
    for (auto *global : tables) {
        global->removeDeadConstantUsers();
        need(global->use_empty(), "AIR routing table has semantic users");
    }
    for (auto *global : tables) global->eraseFromParent();
}

static void instructions(Module &m, size_t &count) {
    for (auto &function : m) for (auto &block : function) for (auto &instruction : block) {
        need(++count <= 131072, "stateless closure instruction bound exceeded");
        if (!(count & 1023)) llvm::hengeAirBudgetCheck();
        if (auto *call = dyn_cast<CallBase>(&instruction))
            need(isa<Function>(call->getCalledOperand()->stripPointerCasts()),
                 "indirect function call is outside the stateless profile");
    }
}

static Bytes link(const Input *inputs, size_t count, const char *entry, bool ios,
                  const std::set<std::string> *expectedImports = nullptr) {
    need(inputs && count && count <= 64 && entry && *entry,
         "invalid stateless closure inputs");
    BudgetScope budget;
    LLVMContext context;
    std::unique_ptr<Module> root;
    std::set<std::string> imports, definitions, compileOptions;
    std::map<const std::set<std::string> *, std::set<std::string>> observedExports;
    size_t total = 0, instructionCount = 0;
    std::string triple, layout;
    for (size_t i = 0; i < count; ++i) {
        llvm::hengeAirBudgetCheck();
        need(inputs[i].bytes && inputs[i].size >= 20 && inputs[i].size <= 4 * 1024 * 1024,
             "AIR input size outside stateless closure bound");
        need(inputs[i].size <= 16 * 1024 * 1024 - total,
             "stateless closure exceeds total input bound");
        total += inputs[i].size;
        auto buffer = MemoryBuffer::getMemBuffer(
            StringRef((const char *)inputs[i].bytes, inputs[i].size), "closure-air", false);
        auto parsed = parseBitcodeFile(buffer->getMemBufferRef(), context);
        if (!parsed) throw std::runtime_error(toString(parsed.takeError()));
        auto module = std::move(*parsed);
        if (inputs[i].exports) observedExports.try_emplace(inputs[i].exports);
        need(!verifyModule(*module, &errs()), "invalid AIR input module");
        version(*module, "air.version", 2, 6);
        // This initial port is qualified against the existing Metal 3.1 controls.
        // Other language profiles remain explicit rejects until exercised.
        version(*module, "air.language_version", 3, 1);
        auto currentOptions = options(*module);
        if (!i) {
            triple = module->getTargetTriple();
            layout = module->getDataLayoutStr();
            compileOptions = currentOptions;
            need(triple == "air64_v26-apple-macosx14.0.0", "unqualified AIR target");
            auto *kernels = module->getNamedMetadata("air.kernel");
            need(kernels && kernels->getNumOperands() == 1 &&
                 !module->getNamedMetadata("air.vertex") &&
                 !module->getNamedMetadata("air.fragment"), "one compute entrypoint required");
            auto *node = kernels->getOperand(0);
            auto *value = node->getNumOperands()
                ? dyn_cast_or_null<ValueAsMetadata>(node->getOperand(0)) : nullptr;
            auto *entryFunction = module->getFunction(entry);
            need(entryFunction && !entryFunction->isDeclaration() &&
                 value && value->getValue() == entryFunction,
                 "consumer entrypoint identity mismatch");
        } else {
            // Apple's shared-library container writes the equivalent AIR2.6
            // target without the executable's _v26 suffix.
            need((module->getTargetTriple() == triple ||
                  module->getTargetTriple() == "air64-apple-macosx14.0") &&
                 module->getDataLayoutStr() == layout,
                 "dependency AIR target/layout mismatch");
            module->setTargetTriple(triple);
            need(currentOptions == compileOptions, "dependency compile options differ");
            need(!module->getNamedMetadata("air.kernel") &&
                 !module->getNamedMetadata("air.vertex") &&
                 !module->getNamedMetadata("air.fragment"), "dependency has executable entrypoints");
            need(module->alias_empty() && module->ifunc_empty(), "dependency alias/ifunc unsupported");
            for (auto &global : module->globals())
                need(global.getName().startswith("air.dyld_") ||
                     global.getName() == "llvm.used" || global.getName() == "llvm.compiler.used",
                     "dependency global storage is outside the stateless profile");
        }
        instructions(*module, instructionCount);
        for (auto &function : *module) if (!function.isDeclaration() && !function.hasLocalLinkage()) {
            if (inputs[i].exports) {
                auto name = function.getName().str();
                need(inputs[i].exports->count(name), "AIR definition missing from container exports");
                observedExports[inputs[i].exports].insert(name);
            }
            need(definitions.insert(function.getName().str()).second,
                 "ambiguous dynamic function definition");
        }
        routing(*module, imports);
        if (!i) root = std::move(module);
        else {
            // Preserve instruction-attached metadata and module flags. The
            // consumer supplies the one executable entrypoint and common AIR
            // metadata, whose versions/options were checked above.
            std::vector<NamedMDNode *> named;
            for (auto &metadata : module->named_metadata())
                if (metadata.getName().startswith("air.")) named.push_back(&metadata);
            for (auto *metadata : named) module->eraseNamedMetadata(metadata);
            need(!Linker::linkModules(*root, std::move(module)), "LLVM closure link failed");
        }
    }
    for (const auto &exports : observedExports)
        need(*exports.first == exports.second, "container export missing a concrete AIR definition");
    if (expectedImports) need(imports == *expectedImports, "container/AIR import inventory differs");
    for (const auto &name : imports) {
        auto *function = root->getFunction(name);
        need(function && !function->isDeclaration(), "unresolved declared dynamic import");
    }
    for (auto &function : *root) {
        if (function.isDeclaration()) {
            need(function.use_empty() || function.getName().startswith("air.") ||
                 function.getName().startswith("llvm."), "unresolved dynamic function");
        } else if (function.getName() != entry) function.setLinkage(GlobalValue::InternalLinkage);
    }
    need(!verifyModule(*root, &errs()), "linked AIR failed validation");
    if (ios) root->setTargetTriple("air64_v26-apple-ios17.0.0");
    SmallVector<char, 0> output;
    raw_svector_ostream stream(output);
    WriteBitcodeToFile140(*root, stream);
    need(output.size() <= 16 * 1024 * 1024, "stateless closure output bound exceeded");
    return Bytes(output.begin(), output.end());
}

struct Library {
    Bytes bytes;
    std::string origin, installName;
    std::vector<std::string> dependencies;
    std::set<std::string> imports;
    std::set<std::string> exports;
    std::vector<Tag> fields;
    std::map<size_t, size_t> modules;
    size_t publicOffset, publicSize, privateOffset, privateSize, bitcodeOffset, bitcodeSize;
    Bytes reflection;
    std::string entry;
};

static std::string stringTag(const Bytes &bytes, const Tag &tag) {
    need(tag.size > 1 && tag.size <= 4097 && bytes[tag.pos + tag.size - 1] == 0,
         "invalid container string");
    std::string result((const char *)bytes.data() + tag.pos, tag.size - 1);
    need(result.find('\0') == std::string::npos, "embedded container string NUL");
    return result;
}

static Library container(const void *input, size_t size, bool dynamic, const char *origin) {
    need(input && size >= 88 && size <= 16 * 1024 * 1024, "container input bound");
    Library result;
    result.bytes.assign((const uint8_t *)input, (const uint8_t *)input + size);
    const auto &b = result.bytes;
    need(!origin || strnlen(origin, 4097) <= 4096, "origin exceeds closure bound");
    result.origin = origin ?: "";
    need(!memcmp(b.data(), "MTLB", 4) && u(b, 4, 2) == 0x8001 &&
         u(b, 6, 2) == 2 && u(b, 8, 2) == 7 && u(b, 10, 1) == (dynamic ? 2 : 0),
         "unsupported executable/dynamic MTLB profile");
    need(u(b, 16, 8) == size, "container declared size mismatch");
    need(u(b, 11, 1) == 0x81 && u(b, 12, 2) == 14 && u(b, 14, 2) == 0,
         "unqualified closure container target");
    size_t fo = u(b, 24, 8), fs = u(b, 32, 8);
    result.publicOffset = u(b, 40, 8); result.publicSize = u(b, 48, 8);
    result.privateOffset = u(b, 56, 8); result.privateSize = u(b, 64, 8);
    result.bitcodeOffset = u(b, 72, 8); result.bitcodeSize = u(b, 80, 8);
    auto po = result.publicOffset, ps = result.publicSize;
    auto vo = result.privateOffset, vs = result.privateSize;
    auto bo = result.bitcodeOffset, bs = result.bitcodeSize;
    need(fo == 88 && fs <= size - fo && fs >= 4 &&
         po >= fo + fs + 4 && po <= size && ps <= size - po &&
         vo == po + ps && vs <= size - vo && bo == vo + vs && bs <= size - bo,
         "unsupported container section layout");
    size_t count = u(b, fo, 4), at = fo + 4;
    need(count > 0 && count <= 4096 && (dynamic || count == 1), "container function inventory bound");
    std::set<std::string> names;
    std::map<size_t, std::array<uint8_t, 32>> hashes;
    std::vector<size_t> reflections;
    for (size_t i = 0; i < count; ++i) {
        size_t n = u(b, at, 4);
        need(n >= 8 && at <= fo + fs + 4 && n <= fo + fs + 4 - at,
             "function record bounds");
        auto fields = tags(b, at + 4, at + n); at += n;
        bool name = false, type = false, hash = false, offset = false, length = false, version = false;
        size_t moduleOffset = 0, moduleSize = 0, hashAt = 0;
        for (const auto &tag : fields) {
            if (tag.key == "NAME") {
                auto function = stringTag(b, tag);
                need(function.size() <= 1024, "function name exceeds closure bound");
                need(names.insert(function).second, "duplicate container export");
                if (!dynamic) result.entry = function;
                name = true;
            } else if (tag.key == "TYPE") {
                need(tag.size == 1 && b[tag.pos] == (dynamic ? 3 : 2), "stateless compute stages only");
                type = true;
            } else if (tag.key == "HASH") {
                need(tag.size == 32, "container HASH size"); hash = true; hashAt = tag.pos;
            } else if (tag.key == "MDSZ") {
                need(tag.size == 8, "container MDSZ size"); length = true; moduleSize = u(b, tag.pos, 8);
            } else if (tag.key == "OFFT") {
                need(tag.size == 24 && u(b, tag.pos, 8) < ps && u(b, tag.pos + 8, 8) < vs,
                     "container metadata offset");
                offset = true; moduleOffset = u(b, tag.pos + 16, 8);
            } else if (tag.key == "VERS") {
                need(tag.size == 8 && u(b, tag.pos, 2) == 2 && u(b, tag.pos + 2, 2) == 6,
                     "container AIR version"); version = true;
            } else if (tag.key == "RFLT") {
                need(tag.size == 8, "container reflection offset size");
                reflections.push_back(u(b, tag.pos, 8));
            } else need(false, "unsupported function tag in closure container");
        }
        need(name && type && hash && offset && length && version,
             "missing closure container function fields");
        need(moduleOffset <= bs && moduleSize >= 20 && moduleSize <= 4 * 1024 * 1024 &&
             moduleSize <= bs - moduleOffset, "closure AIR range");
        auto found = result.modules.emplace(moduleOffset, moduleSize);
        need(found.second || found.first->second == moduleSize, "conflicting shared AIR extent");
        if (found.second) hashes[moduleOffset] = SHA256::hash(
            ArrayRef<uint8_t>(b.data() + bo + moduleOffset, moduleSize));
        need(!memcmp(hashes[moduleOffset].data(), b.data() + hashAt, 32), "closure AIR digest mismatch");
        if (!dynamic) result.fields = std::move(fields);
    }
    result.exports = std::move(names);
    need(at == fo + fs + 4 && result.modules.size() <= 64, "function/AIR section tail or count");
    size_t covered = 0;
    for (const auto &module : result.modules) {
        need(module.first == covered, "uncovered/overlapping AIR bytes"); covered += module.second;
    }
    need(covered == bs, "uncovered AIR tail");
    std::vector<std::pair<size_t, size_t>> tail;
    std::set<size_t> reflectionStarts;
    for (const auto &tag : tags(b, at, po)) {
        if (tag.key == "UUID") { need(tag.size == 16, "container UUID size"); continue; }
        need(tag.key == "HDYN" || tag.key == "ILST" || tag.key == "RLST",
             "unknown closure header extension");
        need(tag.size == 16, "closure extension extent size");
        size_t start = u(b, tag.pos, 8), length = u(b, tag.pos + 8, 8);
        need(start >= bo + bs && start <= size && length <= size - start,
             "closure extension outside tail");
        tail.push_back({start, length});
        if (tag.key == "HDYN") {
            size_t cursor = start, end = start + length;
            bool ended = false;
            while (cursor + 4 <= end) {
                std::string key((const char *)b.data() + cursor, 4);
                if (key == "ENDT") { ended = cursor + 4 == end; break; }
                need(cursor + 6 <= end, "short dynamic header tag");
                size_t n = u(b, cursor + 4, 2);
                need(n <= end - cursor - 6, "dynamic header tag extent");
                auto value = stringTag(b, {key, cursor + 6, n});
                if (key == "NAME") {
                    need(result.installName.empty(), "duplicate dynamic install name");
                    result.installName = value;
                } else if (key == "DYNL") result.dependencies.push_back(value);
                else need(false, "unknown dynamic header tag");
                cursor += 6 + n;
            }
            need(ended, "dynamic header tail");
        } else {
            need(length >= 4, "short closure list");
            size_t entries = u(b, start, 4), cursor = start + 4, end = start + length;
            need(entries <= 4096, "closure list count bound");
            for (size_t i = 0; i < entries; ++i) {
                need(cursor <= end && end - cursor >= 4, "short closure list record");
                size_t n = u(b, cursor, 4);
                need(n >= 8 && cursor <= end && n <= end - cursor, "closure list record bound");
                if (tag.key == "ILST") {
                    auto fields = tags(b, cursor + 4, cursor + n);
                    need(fields.size() == 1 && fields[0].key == "NAME", "unsupported import record");
                    need(result.imports.insert(stringTag(b, fields[0])).second, "duplicate import record");
                } else reflectionStarts.insert(cursor - start);
                cursor += n;
            }
            need(cursor == end, "closure list uncovered bytes");
            if (tag.key == "RLST") result.reflection.assign(b.begin() + start, b.begin() + end);
        }
    }
    std::sort(tail.begin(), tail.end());
    covered = bo + bs;
    for (const auto &part : tail) {
        need(part.first == covered, "uncovered/overlapping container tail"); covered += part.second;
    }
    need(covered == size, "unknown closure container trailing bytes");
    for (size_t offset : reflections)
        need(reflectionStarts.count(offset), "function reflection reference is not a record start");
    need(!dynamic || !result.installName.empty(), "dependency install name missing");
    return result;
}

static std::string originPath(StringRef origin) {
    if (origin.startswith("file:///")) origin = origin.drop_front(7);
    need(origin.startswith("/"), "dependency origin must be a local absolute path");
    SmallString<256> path(origin);
    sys::path::remove_dots(path, true);
    return path.str().str();
}

static void append(Bytes &out, const Bytes &bytes) { out.insert(out.end(), bytes.begin(), bytes.end()); }
static void integer(Bytes &out, unsigned count, uint64_t value) {
    size_t offset = out.size(); out.resize(offset + count); put(out, offset, count, value);
}
static void field(Bytes &out, const char *key, const Bytes &bytes) {
    out.insert(out.end(), key, key + 4); integer(out, 2, bytes.size()); append(out, bytes);
}

static Bytes close(const void *const *bytes, const size_t *sizes, const char *const *origins,
                   size_t count, uint32_t preloaded, const char *entry, bool ios,
                   const char *const *required = nullptr, size_t requiredCount = 0) {
    need(bytes && sizes && origins && count && count <= 17 && !(preloaded & 1) &&
         !(preloaded >> count), "closure input inventory bound");
    std::vector<Library> libraries;
    std::map<std::string, size_t> names, urls;
    size_t total = 0;
    for (size_t i = 0; i < count; ++i) {
        need(sizes[i] <= 16 * 1024 * 1024 - total, "closure total input bound"); total += sizes[i];
        libraries.push_back(container(bytes[i], sizes[i], i != 0, origins[i]));
        if (!i) continue;
        auto name = names.emplace(libraries.back().installName, i);
        need(name.second, "ambiguous dependency install name");
        if (!libraries.back().origin.empty())
            need(urls.emplace(originPath(libraries.back().origin), i).second,
                 "ambiguous dependency origin");
    }
    need(entry && libraries[0].entry == entry, "closure function inventory mismatch");
    need(requiredCount <= 16 && (!requiredCount || required), "compile dependency count bound");
    std::set<std::string> requiredNames;
    for (size_t i = 0; i < requiredCount; ++i) {
        need(required[i] && strnlen(required[i], 4097) <= 4096 && required[i][0] == '/',
             "compile dependency must have an absolute install name");
        need(requiredNames.insert(required[i]).second, "duplicate compile dependency");
        auto found = names.find(required[i]);
        need(found != names.end() && (preloaded & (1u << found->second)),
             "missing explicit compile dependency identity");
    }
    std::vector<size_t> selected;
    std::set<size_t> seen, active;
    std::function<void(size_t)> visit = [&](size_t index) {
        need(!active.count(index), "dynamic dependency cycle unsupported");
        if (seen.count(index)) return;
        active.insert(index);
        for (const auto &dependency : libraries[index].dependencies) {
            size_t target = 0;
            if (StringRef(dependency).startswith("@loader_path/")) {
                need(!libraries[index].origin.empty(), "loader path needs consumer origin");
                auto origin = originPath(libraries[index].origin);
                SmallString<256> resolved(sys::path::parent_path(origin));
                sys::path::append(resolved, StringRef(dependency).drop_front(13));
                auto found = urls.find(originPath(resolved));
                need(found != urls.end(), "missing declared loader dependency"); target = found->second;
            } else {
                need(StringRef(dependency).startswith("/"), "unsupported executable/rpath dependency");
                auto found = names.find(dependency);
                need(found != names.end(), "missing declared absolute dependency"); target = found->second;
            }
            need(libraries[target].installName == dependency, "dependency install-name mismatch");
            visit(target);
        }
        active.erase(index); seen.insert(index);
        if (index) selected.push_back(index);
    };
    visit(0);
    for (size_t i = 1; i < count; ++i) if (preloaded & (1u << i)) visit(i);
    std::vector<Input> modules;
    std::set<std::string> imports;
    auto add = [&](const Library &library) {
        imports.insert(library.imports.begin(), library.imports.end());
        for (const auto &module : library.modules)
            modules.push_back({library.bytes.data() + library.bitcodeOffset + module.first,
                               module.second, &library.exports});
    };
    add(libraries[0]); for (size_t index : selected) add(libraries[index]);
    Bytes linked = link(modules.data(), modules.size(), entry, ios, &imports);
    auto &consumer = libraries[0];
    const auto &original = consumer.bytes;
    Bytes functions; integer(functions, 4, 1);
    Bytes record;
    for (const auto &tag : consumer.fields) {
        Bytes value(original.begin() + tag.pos, original.begin() + tag.pos + tag.size);
        if (tag.key == "HASH") { auto digest = SHA256::hash(linked); value.assign(digest.begin(), digest.end()); }
        else if (tag.key == "MDSZ") put(value, 0, 8, linked.size());
        else if (tag.key == "OFFT") put(value, 16, 8, 0);
        field(record, tag.key.c_str(), value);
    }
    record.insert(record.end(), {'E','N','D','T'});
    integer(functions, 4, record.size() + 4); append(functions, record);
    size_t extensionSize = 22 + 4 + (consumer.reflection.empty() ? 0 : 22);
    size_t po = 88 + functions.size() + extensionSize;
    size_t vo = po + consumer.publicSize, bo = vo + consumer.privateSize;
    Bytes extension;
    if (!consumer.reflection.empty()) {
        Bytes extent; integer(extent, 8, bo + linked.size()); integer(extent, 8, consumer.reflection.size());
        field(extension, "RLST", extent);
    }
    SHA256 identityHash; identityHash.update(original); identityHash.update(linked);
    auto identity = identityHash.final();
    field(extension, "UUID", Bytes(identity.begin(), identity.begin() + 16));
    extension.insert(extension.end(), {'E','N','D','T'});
    Bytes output(original.begin(), original.begin() + 88);
    if (ios) { put(output, 4, 2, 1); put(output, 11, 1, 0x82); put(output, 12, 2, 17); put(output, 14, 2, 0); }
    put(output, 16, 8, bo + linked.size() + consumer.reflection.size());
    put(output, 32, 8, functions.size() - 4);
    put(output, 40, 8, po); put(output, 56, 8, vo); put(output, 72, 8, bo); put(output, 80, 8, linked.size());
    append(output, functions); append(output, extension);
    output.insert(output.end(), original.begin() + consumer.publicOffset,
                  original.begin() + consumer.publicOffset + consumer.publicSize);
    output.insert(output.end(), original.begin() + consumer.privateOffset,
                  original.begin() + consumer.privateOffset + consumer.privateSize);
    append(output, linked); append(output, consumer.reflection);
    need(output.size() <= 16 * 1024 * 1024, "closure container output bound exceeded");
    return output;
}
} // namespace hg_dynamic

extern "C" int HGStatelessMetallibClose(const void *const *bytes, const size_t *sizes,
    const char *const *origins, size_t count, uint32_t preloaded, const char *entry,
    int ios, void **output, size_t *size, char **error) {
    if (!output || !size || !error) return 1;
    *output = nullptr; *size = 0; *error = nullptr;
    try {
        auto result = hg_dynamic::close(bytes, sizes, origins, count, preloaded, entry, ios != 0);
        void *owned = malloc(result.size()); need(owned, "closure output allocation failed");
        memcpy(owned, result.data(), result.size()); *output = owned; *size = result.size(); return 0;
    } catch (const std::exception &failure) { *error = strdup(failure.what()); return 1; }
}

extern "C" int HGStatelessMetallibCloseRequired(const void *const *bytes, const size_t *sizes,
    const char *const *origins, size_t count, uint32_t preloaded, const char *entry,
    const char *const *required, size_t requiredCount, int ios,
    void **output, size_t *size, char **error) {
    if (!output || !size || !error) return 1;
    *output = nullptr; *size = 0; *error = nullptr;
    try {
        auto result = hg_dynamic::close(bytes, sizes, origins, count, preloaded, entry,
                                       ios != 0, required, requiredCount);
        void *owned = malloc(result.size()); need(owned, "closure output allocation failed");
        memcpy(owned, result.data(), result.size()); *output = owned; *size = result.size(); return 0;
    } catch (const std::exception &failure) { *error = strdup(failure.what()); return 1; }
}

extern "C" int HGStatelessAIRLink(const void *const *bytes, const size_t *sizes,
    size_t count, const char *entry, int ios, void **output, size_t *size, char **error) {
    if (!output || !size || !error) return 1;
    *output = nullptr; *size = 0; *error = nullptr;
    try {
        need(bytes && sizes && count && count <= 64, "invalid stateless closure array");
        std::vector<hg_dynamic::Input> inputs;
        for (size_t i = 0; i < count; ++i) inputs.push_back({bytes[i], sizes[i]});
        auto result = hg_dynamic::link(inputs.data(), inputs.size(), entry, ios != 0);
        void *owned = malloc(result.size());
        need(owned, "stateless closure allocation failed");
        memcpy(owned, result.data(), result.size());
        *output = owned; *size = result.size();
        return 0;
    } catch (const std::exception &failure) {
        *error = strdup(failure.what());
        return 1;
    }
}

#ifdef HG_STATELESS_LINK_CLI
int main(int argc, char **argv) {
    if (argc < 5) return 64; // output.air entry ios=0/1 consumer.air [dependency.air...]
    std::vector<std::unique_ptr<MemoryBuffer>> owned;
    std::vector<const void *> bytes;
    std::vector<size_t> sizes;
    for (int i = 4; i < argc; ++i) {
        auto input = MemoryBuffer::getFile(argv[i]);
        if (!input) return 65;
        sizes.push_back((*input)->getBufferSize());
        bytes.push_back((*input)->getBufferStart()); owned.push_back(std::move(*input));
    }
    void *output = nullptr; size_t size = 0; char *error = nullptr;
    int status = HGStatelessAIRLink(bytes.data(), sizes.data(), sizes.size(), argv[2],
                                   atoi(argv[3]), &output, &size, &error);
    if (status) { fprintf(stderr, "%s\n", error ?: "link failed"); free(error); return status; }
    FILE *file = fopen(argv[1], "wb");
    bool okay = file && fwrite(output, 1, size, file) == size;
    if (file) okay = fclose(file) == 0 && okay;
    free(output);
    return okay ? 0 : 66;
}
#endif
