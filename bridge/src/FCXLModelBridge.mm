#import "FCXLModelBridge.h"

#import <assimp/Importer.hpp>
#import <assimp/cimport.h>
#import <assimp/postprocess.h>
#import <assimp/scene.h>

#import <algorithm>
#import <cmath>
#import <string>
#import <vector>

static NSString *const kFCXLModelErrorDomain = @"FCXLModelBridge";

NSString *const FCXLModelTextureBaseColor = @"baseColor";
NSString *const FCXLModelTextureNormal = @"normal";
NSString *const FCXLModelTextureEmissive = @"emissive";
NSString *const FCXLModelTextureRoughness = @"roughness";
NSString *const FCXLModelTextureMetallic = @"metallic";
NSString *const FCXLModelTextureOcclusion = @"occlusion";
NSString *const FCXLModelTextureSpecular = @"specular";

@interface FCXLModelTexture ()
@property (nonatomic, nullable) NSString *path;
@property (nonatomic, nullable) NSData *data;
@end

@implementation FCXLModelTexture
@end

@interface FCXLModelMesh ()
@property (nonatomic) NSData *positions;
@property (nonatomic) NSData *normals;
@property (nonatomic) NSData *texCoords;
@property (nonatomic) NSData *indices;
@property (nonatomic) NSUInteger vertexCount;
@property (nonatomic) NSUInteger faceCount;
@property (nonatomic, nullable) NSColor *diffuseColor;
@property (nonatomic) NSDictionary<NSString *, FCXLModelTexture *> *textures;
@property (nonatomic, nullable) NSNumber *metallic;
@property (nonatomic, nullable) NSNumber *roughness;
@property (nonatomic, nullable) NSNumber *opacity;
@property (nonatomic, nullable) NSColor *emissiveColor;
@property (nonatomic, nullable) NSString *materialName;
@property (nonatomic, nullable) NSString *name;
@end

@implementation FCXLModelMesh
@end

@interface FCXLModelScene ()
@property (nonatomic) NSArray<FCXLModelMesh *> *meshes;
@property (nonatomic) NSUInteger vertexCount;
@property (nonatomic) NSUInteger faceCount;
@end

@implementation FCXLModelScene
@end

namespace {

/// Цвет материала, если он там есть.
NSColor *_Nullable diffuseColour(const aiMaterial *material) {
    if (material == nullptr) { return nil; }
    aiColor4D colour(1, 1, 1, 1);
    // Сначала PBR-цвет (так пишет glTF), потом старый diffuse (FBX, 3DS, OBJ).
    if (material->Get(AI_MATKEY_BASE_COLOR, colour) != AI_SUCCESS &&
        material->Get(AI_MATKEY_COLOR_DIFFUSE, colour) != AI_SUCCESS) {
        return nil;
    }
    return [NSColor colorWithSRGBRed:colour.r green:colour.g blue:colour.b
                               alpha:colour.a <= 0 ? 1 : colour.a];
}

/// Путь к картинке материала — или её номер внутри файла, если картинка вшита.
/// Assimp помечает вшитые звёздочкой: «*0».
std::string textureReference(const aiMaterial *material,
                             const std::vector<aiTextureType> &types) {
    if (material == nullptr) { return {}; }
    aiString path;
    for (aiTextureType type : types) {
        if (material->GetTextureCount(type) > 0 &&
            material->GetTexture(type, 0, &path) == AI_SUCCESS) {
            return std::string(path.C_Str());
        }
    }
    return {};
}

/// Какие виды карт Assimp отдаёт под каждое наше гнездо. Виды перечислены по порядку
/// предпочтения: сначала как их называет glTF/PBR, потом старые имена (OBJ, FBX).
const std::vector<std::pair<NSString *, std::vector<aiTextureType>>> &textureSlots() {
    static const std::vector<std::pair<NSString *, std::vector<aiTextureType>>> slots = {
        {FCXLModelTextureBaseColor, {aiTextureType_BASE_COLOR, aiTextureType_DIFFUSE}},
        {FCXLModelTextureNormal,    {aiTextureType_NORMALS, aiTextureType_NORMAL_CAMERA,
                                     aiTextureType_HEIGHT}},
        {FCXLModelTextureEmissive,  {aiTextureType_EMISSION_COLOR, aiTextureType_EMISSIVE}},
        {FCXLModelTextureRoughness, {aiTextureType_DIFFUSE_ROUGHNESS}},
        {FCXLModelTextureMetallic,  {aiTextureType_METALNESS}},
        {FCXLModelTextureOcclusion, {aiTextureType_AMBIENT_OCCLUSION, aiTextureType_LIGHTMAP}},
        {FCXLModelTextureSpecular,  {aiTextureType_SPECULAR}},
    };
    return slots;
}

/// Нормали, пригодные для света.
///
/// Бывает, что файл несёт массив нормалей из одних НУЛЕЙ — так пишут некоторые
/// экспортёры (проверено на своих же .glb и .fbx: средняя длина нормали 0.000 на всех
/// 1819 вершинах). Assimp такое не лечит: aiProcess_GenSmoothNormals считает нормали
/// только когда их нет ВОВСЕ, а нули — это «есть». Модель тогда выходит ровным плоским
/// пятном: на снимке ровно один оттенок, свету не за что зацепиться.
///
/// Поэтому проверяем и, если нормали негодные, считаем свои — средние по граням,
/// сходящимся в вершине.
NSData *usableNormals(const aiMesh *mesh) {
    const unsigned count = mesh->mNumVertices;
    if (count == 0) { return [NSData data]; }
    if (mesh->mNormals != nullptr) {
        // Хватает и выборки: массив либо осмысленный целиком, либо нулевой целиком.
        double sum = 0;
        const unsigned step = std::max(1u, count / 64);
        unsigned taken = 0;
        for (unsigned v = 0; v < count; v += step) {
            const aiVector3D n = mesh->mNormals[v];
            sum += std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
            taken++;
        }
        if (taken > 0 && sum / taken > 0.5) {
            return [NSData dataWithBytes:mesh->mNormals length:sizeof(aiVector3D) * count];
        }
    }
    std::vector<aiVector3D> normals(count, aiVector3D(0, 0, 0));
    for (unsigned f = 0; f < mesh->mNumFaces; f++) {
        const aiFace &face = mesh->mFaces[f];
        if (face.mNumIndices != 3) { continue; }
        const unsigned a = face.mIndices[0], b = face.mIndices[1], c = face.mIndices[2];
        if (a >= count || b >= count || c >= count) { continue; }
        const aiVector3D edge1 = mesh->mVertices[b] - mesh->mVertices[a];
        const aiVector3D edge2 = mesh->mVertices[c] - mesh->mVertices[a];
        const aiVector3D face_normal = edge1 ^ edge2;   // векторное произведение
        normals[a] += face_normal;
        normals[b] += face_normal;
        normals[c] += face_normal;
    }
    for (auto &normal : normals) {
        const float length = std::sqrt(normal.x * normal.x + normal.y * normal.y
                                       + normal.z * normal.z);
        if (length > 1e-8f) { normal /= length; } else { normal = aiVector3D(0, 1, 0); }
    }
    return [NSData dataWithBytes:normals.data() length:sizeof(aiVector3D) * count];
}

/// Число из материала или nil, если файл о нём молчит.
NSNumber *_Nullable materialNumber(const aiMaterial *material, const char *key,
                                   unsigned type, unsigned index) {
    if (material == nullptr) { return nil; }
    float value = 0;
    if (material->Get(key, type, index, value) != AI_SUCCESS) { return nil; }
    return @(value);
}

}  // namespace

@implementation FCXLModelBridge

+ (NSArray<NSString *> *)readableExtensions {
    aiString list;
    aiGetExtensionList(&list);
    NSString *raw = [NSString stringWithUTF8String:list.C_Str() ?: ""];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *item in [raw componentsSeparatedByString:@";"]) {
        NSString *ext = [item stringByReplacingOccurrencesOfString:@"*." withString:@""];
        ext = [ext stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (ext.length > 0) { [result addObject:ext.lowercaseString]; }
    }
    return result;
}

+ (nullable FCXLModelScene *)loadModelAtPath:(NSString *)path error:(NSError **)error {
    Assimp::Importer importer;
    // Точки и линии выбрасываем: просмотрщик рисует поверхности, а болтающиеся рёбра
    // ломают расчёт границ модели — камера потом смотрит в пустоту.
    importer.SetPropertyInteger(AI_CONFIG_PP_SBP_REMOVE,
                                aiPrimitiveType_POINT | aiPrimitiveType_LINE);
    const unsigned flags = aiProcess_Triangulate
        | aiProcess_GenSmoothNormals
        | aiProcess_JoinIdenticalVertices
        | aiProcess_SortByPType
        // Дерево узлов сплющиваем: для просмотра важна сама модель, а не её сборка, и
        // каждая сетка приходит уже в мировых координатах — не надо тащить в Swift
        // матрицы преобразований.
        | aiProcess_PreTransformVertices
        // У SceneKit начало развёртки сверху, у Assimp — снизу; без этого картинка
        // материала ложится вверх ногами.
        | aiProcess_FlipUVs;

    const aiScene *scene = importer.ReadFile(path.fileSystemRepresentation, flags);
    if (scene == nullptr || scene->mNumMeshes == 0) {
        if (error != nullptr) {
            const char *message = importer.GetErrorString();
            NSString *text = (message != nullptr && *message != '\0')
                ? [NSString stringWithUTF8String:message]
                : @"no meshes";
            *error = [NSError errorWithDomain:kFCXLModelErrorDomain code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: text ?: @"unreadable" }];
        }
        return nil;
    }

    NSMutableArray<FCXLModelMesh *> *meshes = [NSMutableArray arrayWithCapacity:scene->mNumMeshes];
    NSUInteger totalVertices = 0, totalFaces = 0;

    for (unsigned m = 0; m < scene->mNumMeshes; m++) {
        const aiMesh *mesh = scene->mMeshes[m];
        if (mesh == nullptr || mesh->mNumVertices == 0 || mesh->mNumFaces == 0) { continue; }

        FCXLModelMesh *out = [FCXLModelMesh new];
        out.vertexCount = mesh->mNumVertices;
        out.name = mesh->mName.length > 0 ? [NSString stringWithUTF8String:mesh->mName.C_Str()] : nil;
        // aiVector3D — это ровно три float, поэтому весь массив копируется одним куском.
        out.positions = [NSData dataWithBytes:mesh->mVertices
                                       length:sizeof(aiVector3D) * mesh->mNumVertices];
        out.normals = usableNormals(mesh);

        if (mesh->HasTextureCoords(0)) {
            // Развёртка у Assimp трёхмерная (u, v, w); SceneKit ждёт две координаты —
            // третью отбрасываем, иначе поедут все шаги в буфере.
            std::vector<float> uv;
            uv.reserve(mesh->mNumVertices * 2);
            for (unsigned v = 0; v < mesh->mNumVertices; v++) {
                uv.push_back(mesh->mTextureCoords[0][v].x);
                uv.push_back(mesh->mTextureCoords[0][v].y);
            }
            out.texCoords = [NSData dataWithBytes:uv.data() length:uv.size() * sizeof(float)];
        } else {
            out.texCoords = [NSData data];
        }

        std::vector<uint32_t> indices;
        indices.reserve(mesh->mNumFaces * 3);
        for (unsigned f = 0; f < mesh->mNumFaces; f++) {
            const aiFace &face = mesh->mFaces[f];
            if (face.mNumIndices != 3) { continue; }   // после триангуляции бывает редко
            indices.push_back(face.mIndices[0]);
            indices.push_back(face.mIndices[1]);
            indices.push_back(face.mIndices[2]);
        }
        if (indices.empty()) { continue; }
        out.indices = [NSData dataWithBytes:indices.data() length:indices.size() * sizeof(uint32_t)];
        out.faceCount = indices.size() / 3;

        const aiMaterial *material = (mesh->mMaterialIndex < scene->mNumMaterials)
            ? scene->mMaterials[mesh->mMaterialIndex] : nullptr;
        out.diffuseColor = diffuseColour(material);
        if (material != nullptr) {
            aiString materialName;
            if (material->Get(AI_MATKEY_NAME, materialName) == AI_SUCCESS &&
                materialName.length > 0) {
                out.materialName = [NSString stringWithUTF8String:materialName.C_Str()];
            }
            out.metallic = materialNumber(material, AI_MATKEY_METALLIC_FACTOR);
            out.roughness = materialNumber(material, AI_MATKEY_ROUGHNESS_FACTOR);
            out.opacity = materialNumber(material, AI_MATKEY_OPACITY);
            aiColor4D emissive(0, 0, 0, 1);
            if (material->Get(AI_MATKEY_COLOR_EMISSIVE, emissive) == AI_SUCCESS) {
                out.emissiveColor = [NSColor colorWithSRGBRed:emissive.r green:emissive.g
                                                         blue:emissive.b alpha:1];
            }
        }

        NSMutableDictionary<NSString *, FCXLModelTexture *> *textures = [NSMutableDictionary dictionary];
        for (const auto &slot : textureSlots()) {
            const std::string reference = textureReference(material, slot.second);
            if (reference.empty()) { continue; }
            FCXLModelTexture *texture = [FCXLModelTexture new];
            if (reference[0] == '*') {
                // Картинка внутри файла: «*3» — это номер в списке scene->mTextures.
                const unsigned index = (unsigned)atoi(reference.c_str() + 1);
                if (index < scene->mNumTextures) {
                    const aiTexture *embedded = scene->mTextures[index];
                    if (embedded->mHeight == 0) {
                        // Сжатая картинка (png/jpg) лежит как есть — её прочтёт NSImage.
                        texture.data = [NSData dataWithBytes:embedded->pcData
                                                      length:embedded->mWidth];
                    }
                }
            } else {
                texture.path = [NSString stringWithUTF8String:reference.c_str()];
            }
            if (texture.path != nil || texture.data != nil) { textures[slot.first] = texture; }
        }
        out.textures = textures;

        totalVertices += out.vertexCount;
        totalFaces += out.faceCount;
        [meshes addObject:out];
    }

    if (meshes.count == 0) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:kFCXLModelErrorDomain code:2
                                     userInfo:@{ NSLocalizedDescriptionKey: @"no triangles" }];
        }
        return nil;
    }

    FCXLModelScene *result = [FCXLModelScene new];
    result.meshes = meshes;
    result.vertexCount = totalVertices;
    result.faceCount = totalFaces;
    return result;
}

@end
