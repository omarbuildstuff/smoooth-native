import { useState, useEffect } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { EditorPage } from './pages/EditorPage'
import { RecorderPage } from './pages/RecorderPage'
import { RendererPage } from './pages/RendererPage'
import { useEditorStore } from './store/editorStore'

function App() {
  const [route, setRoute] = useState(window.location.hash)
  const { mode } = useEditorStore(
    useShallow((state) => ({
      mode: state.mode,
    })),
  )
  const { initializeSettings } = useEditorStore.getState()

  useEffect(() => {
    initializeSettings()
  }, [initializeSettings])

  useEffect(() => {
    const root = document.documentElement
    root.setAttribute('data-theme', 'ocean-blue')

    if (mode === 'dark') {
      root.classList.add('dark')
    } else {
      root.classList.remove('dark')
    }
  }, [mode])

  useEffect(() => {
    const handleHashChange = () => {
      setRoute(window.location.hash)
    }

    window.addEventListener('hashchange', handleHashChange)
    return () => {
      window.removeEventListener('hashchange', handleHashChange)
    }
  }, [])

  if (route.startsWith('#renderer')) {
    return <RendererPage />
  }

  if (route.startsWith('#editor')) {
    return <EditorPage />
  }

  return <RecorderPage />
}

export default App
