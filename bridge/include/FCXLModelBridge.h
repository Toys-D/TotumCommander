#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Картинка материала: либо путь (может быть и с чужой машины — искать по имени), либо
/// сами байты, если она лежит ВНУТРИ файла модели (так устроен .glb).
@interface FCXLModelTexture : NSObject
@property (nonatomic, readonly, nullable) NSString *path;
@property (nonatomic, readonly, nullable) NSData *data;
/// Каким набором развёртки её накладывать.
///
/// Наборов у модели бывает несколько, и разные карты пользуются разными: у этой машины
/// цвет фонаря лежит в наборе 0, а красное стекло — в наборе 1. Наложишь вторую картинку
/// первым набором — попадёшь не туда, и фонарь останется белым.
@property (nonatomic, readonly) NSInteger uvChannel;
@end

/// Имена гнёзд, по которым раскладываются картинки материала.
extern NSString *const FCXLModelTextureBaseColor;
extern NSString *const FCXLModelTextureNormal;
extern NSString *const FCXLModelTextureEmissive;
extern NSString *const FCXLModelTextureRoughness;
extern NSString *const FCXLModelTextureMetallic;
extern NSString *const FCXLModelTextureOcclusion;
extern NSString *const FCXLModelTextureSpecular;

/// Одна сетка модели — ровно в том виде, в каком её принимает SceneKit: вершины,
/// нормали и развёртка плотными массивами float, номера граней — uint32.
///
/// Почему так, а не готовой SCNGeometry: мост говорит на C++ (Assimp), а SceneKit —
/// фреймворк Swift/ObjC, и собирать геометрию удобнее там, где потом с ней и работают.
/// Мост отдаёт сырые числа и ничего не знает о просмотрщике.
@interface FCXLModelMesh : NSObject

/// Вершины: по три float на вершину, без пропусков.
@property (nonatomic, readonly) NSData *positions;
/// Нормали в том же порядке; пусто, если у модели их нет и посчитать не удалось.
@property (nonatomic, readonly) NSData *normals;
/// Развёртка: по два float на вершину; пусто, если модель без развёртки.
@property (nonatomic, readonly) NSData *texCoords;
/// Все наборы развёртки — в том же порядке, в каком на них ссылается uvChannel.
@property (nonatomic, readonly) NSArray<NSData *> *texCoordSets;
/// Номера вершин по три на треугольник.
@property (nonatomic, readonly) NSData *indices;
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger faceCount;
/// Цвет материала, если он задан.
@property (nonatomic, readonly, nullable) NSColor *diffuseColor;
/// Картинки материала по гнёздам: цвет, нормали, свечение, шероховатость, металл…
///
/// Не одна «текстура», а все: физически верный материал без металличности и
/// шероховатости выходит матовой болванкой — чёрный кузов «металлик» так и остаётся
/// чёрным силуэтом, сколько света вокруг ни ставь.
@property (nonatomic, readonly) NSDictionary<NSString *, FCXLModelTexture *> *textures;
/// Числа материала — из них SceneKit делает блеск и отражения. nil, если файл молчит.
@property (nonatomic, readonly, nullable) NSNumber *metallic;
@property (nonatomic, readonly, nullable) NSNumber *roughness;
@property (nonatomic, readonly, nullable) NSNumber *opacity;
@property (nonatomic, readonly, nullable) NSColor *emissiveColor;
/// Сила свечения (в glTF это KHR_materials_emissive_strength): у фонаря она бывает
/// десятикратной, и без неё стекло светится еле-еле.
@property (nonatomic, readonly, nullable) NSNumber *emissiveStrength;
@property (nonatomic, readonly, nullable) NSString *materialName;
@property (nonatomic, readonly, nullable) NSString *name;

@end

/// Модель целиком.
@interface FCXLModelScene : NSObject

@property (nonatomic, readonly) NSArray<FCXLModelMesh *> *meshes;
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger faceCount;

@end

/// Чтение моделей тех форматов, которых нет у Apple: glTF/GLB, FBX, 3DS и ещё десятки.
///
/// Форматы, которые macOS читает сам (obj, stl, ply, abc, usd*, dae), через этот мост НЕ
/// идут: у Model I/O и SceneKit они получаются и быстрее, и вместе с материалами. Мост —
/// про остальные.
@interface FCXLModelBridge : NSObject

/// Расширения, которые библиотека действительно умеет читать, — спрошены у неё самой, а
/// не выписаны в код: список так не устареет при обновлении библиотеки.
+ (NSArray<NSString *> *)readableExtensions;

/// Читает модель. nil и `error` — если не получилось; сообщение в `error` от самой
/// библиотеки, чтобы человек видел причину, а не «не удалось открыть».
+ (nullable FCXLModelScene *)loadModelAtPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
