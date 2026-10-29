package com.icamlink.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.icamlink.app.data.Camera
import com.icamlink.app.stream.ProbeResult
import com.icamlink.app.stream.RtspProbe
import kotlinx.coroutines.launch

private sealed interface Pane {
    data object None : Pane
    data object Scan : Pane
    data class Edit(val camera: Camera?) : Pane
}

@Composable
fun SettingsScreen(vm: AppViewModel) {
    var pane by remember { mutableStateOf<Pane>(Pane.None) }
    var deleting by remember { mutableStateOf<Camera?>(null) }

    BackHandler {
        if (pane != Pane.None) {
            vm.stopScan()
            pane = Pane.None
        } else {
            vm.closeSettings()
        }
    }

    Row(
        Modifier
            .fillMaxSize()
            .background(ICamColors.Background)
            .windowInsetsPadding(WindowInsets.displayCutout)
            .windowInsetsPadding(WindowInsets.systemBars)
    ) {
        // Left: header, actions and the registered cameras.
        Column(
            Modifier
                .weight(0.42f)
                .fillMaxHeight()
                .background(ICamColors.Surface)
                .padding(16.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = vm::closeSettings) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Volver", tint = ICamColors.OnSurface)
                }
                Text("Configuración", style = MaterialTheme.typography.titleLarge, color = ICamColors.OnSurface)
            }
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = {
                    pane = Pane.Scan
                    vm.startScan()
                },
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.large,
            ) {
                Icon(Icons.Filled.Radar, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Escanear red local")
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(
                onClick = {
                    vm.stopScan()
                    pane = Pane.Edit(null)
                },
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.large,
            ) {
                Icon(Icons.Filled.Add, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Agregar manualmente")
            }
            Spacer(Modifier.height(16.dp))
            SectionTitle("CÁMARAS (${vm.cameras.size})")
            Spacer(Modifier.height(4.dp))
            if (vm.cameras.isEmpty()) {
                Text("Aún no hay cámaras.", color = ICamColors.Muted, fontSize = 13.sp)
            }
            val listState = rememberLazyListState()
            var draggingId by remember { mutableStateOf<String?>(null) }
            var dragOffset by remember { mutableFloatStateOf(0f) }
            LazyColumn(Modifier.weight(1f), state = listState) {
                items(vm.cameras, key = { it.id }) { camera ->
                    val dragging = draggingId == camera.id
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .zIndex(if (dragging) 1f else 0f)
                            .graphicsLayer { translationY = if (dragging) dragOffset else 0f }
                            .background(if (dragging) ICamColors.SurfaceVariant else ICamColors.Surface)
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Long list reordering: dragging the handle swaps with the row under its center.
                        Icon(
                            Icons.Filled.DragHandle,
                            contentDescription = "Arrastrar para reordenar",
                            tint = ICamColors.Muted,
                            modifier = Modifier
                                .padding(end = 8.dp)
                                .size(24.dp)
                                .pointerInput(camera.id) {
                                    detectDragGestures(
                                        onDragStart = {
                                            draggingId = camera.id
                                            dragOffset = 0f
                                        },
                                        onDragEnd = { draggingId = null },
                                        onDragCancel = { draggingId = null },
                                    ) { change, amount ->
                                        change.consume()
                                        dragOffset += amount.y
                                        val items = listState.layoutInfo.visibleItemsInfo
                                        val me = items.firstOrNull { it.key == camera.id } ?: return@detectDragGestures
                                        val center = me.offset + me.size / 2 + dragOffset
                                        val target = items.firstOrNull {
                                            it.key != camera.id && center >= it.offset && center < it.offset + it.size
                                        } ?: return@detectDragGestures
                                        vm.move(me.index, target.index)
                                        dragOffset += (me.offset - target.offset)
                                    }
                                },
                        )
                        Column(Modifier.weight(1f)) {
                            Text(camera.name, color = ICamColors.OnSurface, maxLines = 1)
                            Text("${camera.host}:${camera.port}", color = ICamColors.Muted, fontSize = 12.sp)
                        }
                        IconButton(onClick = {
                            vm.stopScan()
                            pane = Pane.Edit(camera)
                        }) { Icon(Icons.Filled.Edit, "Editar", tint = ICamColors.Muted) }
                        IconButton(onClick = { deleting = camera }) {
                            Icon(Icons.Filled.Delete, "Eliminar", tint = ICamColors.Error)
                        }
                    }
                    HorizontalDivider(color = ICamColors.Outline)
                }
            }
        }

        // Right: scan results or the add/edit form.
        Box(
            Modifier
                .weight(0.58f)
                .fillMaxHeight()
                .padding(16.dp)
        ) {
            when (val p = pane) {
                Pane.None -> Text(
                    "Escanea la red o agrega una cámara manualmente.",
                    modifier = Modifier.align(Alignment.Center),
                    color = ICamColors.Muted,
                )
                Pane.Scan -> ScanPane(vm, onDone = { pane = Pane.None })
                is Pane.Edit -> EditorPane(
                    vm = vm,
                    camera = p.camera,
                    onDone = { pane = Pane.None },
                )
            }
        }
    }

    deleting?.let { camera ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Eliminar cámara") },
            text = { Text("¿Eliminar \"${camera.name}\" (${camera.host})?") },
            confirmButton = {
                TextButton(onClick = {
                    vm.delete(camera.id)
                    if ((pane as? Pane.Edit)?.camera?.id == camera.id) pane = Pane.None
                    deleting = null
                }) { Text("Eliminar", color = ICamColors.Error) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancelar") } },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, color = ICamColors.Muted, fontSize = 13.sp, letterSpacing = 0.4.sp, style = MaterialTheme.typography.labelLarge)
}

// --- A. Network scan ---------------------------------------------------------------------------

@Composable
private fun ScanPane(vm: AppViewModel, onDone: () -> Unit) {
    var selected by remember { mutableStateOf(setOf<String>()) }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var testMessage by remember { mutableStateOf<ProbeResult?>(null) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val chosen = vm.found.filter { it.host in selected && !vm.isRegistered(it.host) }

    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionTitle("CÁMARAS ENCONTRADAS (${vm.found.size})")
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { if (vm.scanning) vm.stopScan() else vm.startScan() }) {
                Text(if (vm.scanning) "Detener" else "Volver a escanear")
            }
        }
        if (vm.scanning) {
            LinearProgressIndicator(
                progress = { vm.scanProgress },
                modifier = Modifier.fillMaxWidth(),
                color = ICamColors.Accent,
                trackColor = ICamColors.Outline,
            )
        }
        vm.scanError?.let { Text(it, color = ICamColors.Error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp)) }

        LazyColumn(Modifier.weight(1f).padding(top = 4.dp)) {
            if (!vm.scanning && vm.found.isEmpty() && vm.scanError == null) {
                item { Text("No se encontraron cámaras.", color = ICamColors.Muted, modifier = Modifier.padding(top = 12.dp)) }
            }
            items(vm.found, key = { it.host }) { cam ->
                val registered = vm.isRegistered(cam.host)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !registered) {
                            selected = if (cam.host in selected) selected - cam.host else selected + cam.host
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = cam.host in selected || registered,
                        onCheckedChange = null,
                        enabled = !registered,
                        colors = CheckboxDefaults.colors(checkedColor = ICamColors.Accent),
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                    Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                        Text(cam.name ?: "Cámara ${cam.host.substringAfterLast('.')}", color = ICamColors.OnSurface)
                        Text(cam.host, color = ICamColors.Muted, fontSize = 12.sp)
                    }
                    Text(
                        when {
                            registered -> "Ya agregada"
                            cam.onvif -> "ONVIF"
                            else -> "RTSP"
                        },
                        color = if (cam.onvif && !registered) ICamColors.Accent else ICamColors.Muted,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
                HorizontalDivider(color = ICamColors.Outline)
            }
        }

        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = user,
                onValueChange = { user = it; testMessage = null },
                label = { Text("Usuario RTSP") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = pass,
                onValueChange = { pass = it; testMessage = null },
                label = { Text("Contraseña RTSP") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.weight(1f),
            )
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                enabled = chosen.isNotEmpty() && user.isNotBlank() && !testing,
                onClick = {
                    testing = true
                    testMessage = null
                    scope.launch {
                        testMessage = RtspProbe.probe(chosen.first().host, 554, user.trim(), pass)
                        testing = false
                    }
                },
                shape = MaterialTheme.shapes.large,
            ) { Text(if (testing) "Probando…" else "Probar") }
            Button(
                enabled = chosen.isNotEmpty() && user.isNotBlank(),
                onClick = {
                    vm.addDiscovered(chosen, user.trim(), pass)
                    vm.stopScan()
                    onDone()
                },
                shape = MaterialTheme.shapes.large,
            ) { Text("Añadir (${chosen.size})") }
            testMessage?.let {
                Text(it.message, color = if (it.ok) ICamColors.Live else ICamColors.Error, fontSize = 12.sp, modifier = Modifier.weight(1f))
            }
        }
    }
}

// --- B. Manual add / edit ----------------------------------------------------------------------

@Composable
private fun EditorPane(vm: AppViewModel, camera: Camera?, onDone: () -> Unit) {
    var name by remember(camera) { mutableStateOf(camera?.name.orEmpty()) }
    var host by remember(camera) { mutableStateOf(camera?.host.orEmpty()) }
    var port by remember(camera) { mutableStateOf((camera?.port ?: 554).toString()) }
    var user by remember(camera) { mutableStateOf(camera?.username.orEmpty()) }
    var pass by remember(camera) { mutableStateOf(camera?.password.orEmpty()) }
    var result by remember(camera) { mutableStateOf<ProbeResult?>(null) }
    var testing by remember(camera) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val portNumber = port.toIntOrNull()?.takeIf { it in 1..65535 }
    val valid = name.isNotBlank() && host.isNotBlank() && portNumber != null && user.isNotBlank()

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle(if (camera == null) "NUEVA CÁMARA" else "EDITAR CÁMARA")
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Nombre personalizado") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = host,
                onValueChange = { host = it.trim(); result = null },
                label = { Text("Dirección IP") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.weight(2f),
            )
            OutlinedTextField(
                value = port,
                onValueChange = { port = it.filter(Char::isDigit).take(5); result = null },
                label = { Text("Puerto RTSP") },
                singleLine = true,
                isError = portNumber == null,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = user,
                onValueChange = { user = it; result = null },
                label = { Text("Usuario RTSP") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = pass,
                onValueChange = { pass = it; result = null },
                label = { Text("Contraseña RTSP") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                modifier = Modifier.weight(1f),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                enabled = valid && !testing,
                onClick = {
                    testing = true
                    result = null
                    scope.launch {
                        result = RtspProbe.probe(host, portNumber!!, user.trim(), pass)
                        testing = false
                    }
                },
                shape = MaterialTheme.shapes.large,
            ) { Text(if (testing) "Probando…" else "Probar conexión") }
            Button(
                enabled = valid,
                onClick = {
                    vm.upsert(
                        (camera ?: Camera(name = name, host = host, username = user, password = pass)).copy(
                            name = name.trim(),
                            host = host,
                            port = portNumber!!,
                            username = user.trim(),
                            password = pass,
                        )
                    )
                    onDone()
                },
                shape = MaterialTheme.shapes.large,
            ) { Text("Guardar") }
            TextButton(onClick = onDone) { Text("Cancelar") }
        }
        result?.let { Text(it.message, color = if (it.ok) ICamColors.Live else ICamColors.Error, fontSize = 13.sp) }
    }
}
