#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
/// Номера вершин по три на треугольник.
@property (nonatomic, readonly) NSData *indices;
@property (nonatomic, readonly) NSUInteger vertexCount;
@property (nonatomic, readonly) NSUInteger faceCount;
/// Цвет материала, если он задан.
@property (nonatomic, readonly, nullable) NSColor *diffuseColor;
/// Картинка материала: путь рядом с моделью…
@property (nonatomic, readonly, nullable) NSString *texturePath;
/// …или сами байты, если она лежит ВНУТРИ файла (так устроен .glb).
@property (nonatomic, readonly, nullable) NSData *textureData;
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
