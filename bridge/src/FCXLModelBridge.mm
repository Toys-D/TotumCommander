#import "FCXLModelBridge.h"

#import <assimp/Importer.hpp>
#import <assimp/cimport.h>
#import <assimp/postprocess.h>
#import <assimp/scene.h>

#import <string>
#import <vector>

static NSString *const kFCXLModelErrorDomain = @"FCXLModelBridge";

@interface FCXLModelMesh ()
@property (nonatomic) NSData *positions;
@property (nonatomic) NSData *normals;
@property (nonatomic) NSData *texCoords;
@property (nonatomic) NSData *indices;
@property (nonatomic) NSUInteger vertexCount;
@property (nonatomic) NSUInteger faceCount;
@property (nonatomic, nullable) NSColor *diffuseColor;
@property (nonatomic, nullable) NSString *texturePath;
@property (nonatomic, nullable) NSData *textureData;
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
std::string diffuseTexture(const aiMaterial *material) {
    if (material == nullptr) { return {}; }
    aiString path;
    for (aiTextureType type : {aiTextureType_BASE_COLOR, aiTextureType_DIFFUSE}) {
        if (material->GetTextureCount(type) > 0 &&
            material->GetTexture(type, 0, &path) == AI_SUCCESS) {
            return std::string(path.C_Str());
        }
    }
    return {};
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
        out.normals = mesh->HasNormals()
            ? [NSData dataWithBytes:mesh->mNormals length:sizeof(aiVector3D) * mesh->mNumVertices]
            : [NSData data];

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
        const std::string texture = diffuseTexture(material);
        if (!texture.empty()) {
            if (texture[0] == '*') {
                // Картинка внутри файла: «*3» — это номер в списке scene->mTextures.
                const unsigned index = (unsigned)atoi(texture.c_str() + 1);
                if (index < scene->mNumTextures) {
                    const aiTexture *embedded = scene->mTextures[index];
                    if (embedded->mHeight == 0) {
                        // Сжатая картинка (png/jpg) лежит как есть — её прочтёт NSImage.
                        out.textureData = [NSData dataWithBytes:embedded->pcData
                                                         length:embedded->mWidth];
                    }
                }
            } else {
                out.texturePath = [NSString stringWithUTF8String:texture.c_str()];
            }
        }

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
